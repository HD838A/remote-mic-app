"""An in-memory fake of the locked ``winrt-Windows.*==3.2.1`` Python
projection surface that ``ble_transport_winrt.py`` calls, matching the real
method names/argument types (uuid.UUID, not str; direct-enum vs.
result-object return shapes; event tokens) as closely as this project can
verify without a live Windows/WinRT runtime.

Used only by tests/test_ble_transport_contract.py. If a production call
site uses a method name this fake doesn't define, or passes an argument
type the fake asserts against, the test fails with a clear AttributeError/
AssertionError instead of silently "working" - that is the whole point:
this is a contract test, not a mock that rubber-stamps whatever is called.

BLE-device vs. GATT-service ID domains (XRBM-018, fixing XRBM-014 review
round 2 P1 #2): ``BluetoothLEDevice.from_id_async()`` and
``GattDeviceService.get_device_selector_from_uuid()`` occupy two distinct
WinRT ID/selector domains. This fake models both, on purpose:
``PAIRED_DEVICE_SELECTOR``/``FakeBluetoothLEDeviceFactory.from_id_async``
model the (correct) BLE-device domain production code now uses exclusively;
``gatt_service_instance_id()`` below builds a same-shaped-but-wrong-domain
ID string purely so a test can assert that feeding it to
``from_id_async`` is rejected, not silently accepted.
"""

from __future__ import annotations

import uuid
from typing import Any, Dict, List, Optional

# Distinct from any GATT-service-domain selector string (see
# gatt_service_instance_id() below) so a regression back to the wrong WinRT
# ID domain fails loudly instead of "coincidentally" still matching.
PAIRED_DEVICE_SELECTOR = "System.Devices.Aep.Bluetooth.IssueInquiry:=BluetoothLE-PairedDeviceSelector"


def gatt_service_instance_id(service_uuid: uuid.UUID) -> str:
    """Builds a plausible GATT *service-instance* path - the wrong-domain ID
    the XRBM-014 round-2 regression (get_device_selector_from_uuid's result)
    would have produced. Used only by tests that assert this ID domain is
    rejected when passed to BluetoothLEDevice.from_id_async.
    """

    return f"Bluetooth#BluetoothAA:BB:CC:DD:EE:FF-GattServiceInstance-{service_uuid}"


class FakeGattCommunicationStatus:
    SUCCESS = 0
    UNREACHABLE = 1
    PROTOCOL_ERROR = 2
    ACCESS_DENIED = 3


class FakeGattClientCharacteristicConfigurationDescriptorValue:
    NONE = 0
    NOTIFY = 1
    INDICATE = 2


class FakeBluetoothConnectionStatus:
    DISCONNECTED = 0
    CONNECTED = 1


class FakeBluetoothCacheMode:
    CACHED = 0
    UNCACHED = 1


class FakeGattWriteResult:
    def __init__(self, status: int) -> None:
        self.status = status


class FakeGattServicesResult:
    def __init__(self, status: int, services: List["FakeGattDeviceService"]) -> None:
        self.status = status
        self.services = services


class FakeGattCharacteristicsResult:
    def __init__(self, status: int, characteristics: List["FakeGattCharacteristic"]) -> None:
        self.status = status
        self.characteristics = characteristics


class FakeEventArgs:
    def __init__(self, payload: bytes) -> None:
        self.characteristic_value = payload


class FakeDataWriter:
    def __init__(self) -> None:
        self._buffer = b""

    def write_bytes(self, value: bytes) -> None:
        assert isinstance(value, (bytes, bytearray)), (
            f"write_bytes must be called with real bytes, got {type(value)!r}"
        )
        self._buffer += bytes(value)

    def detach_buffer(self) -> bytes:
        return self._buffer


class FakeGattCharacteristic:
    def __init__(self, characteristic_uuid: uuid.UUID, on_write=None) -> None:
        self.uuid = characteristic_uuid
        self._handlers: Dict[int, Any] = {}
        self._next_token = 1
        self.cccd_history: List[int] = []
        self._on_write = on_write
        self.write_history: List[bytes] = []
        # Test-only controllable blocking hook (XRBM-018 RETRY 1 P1 #3):
        # when set to an ``asyncio.Event``, write_value_with_result_async()
        # blocks on it (after incrementing write_started_count, so a test
        # can deterministically wait until the write is genuinely in
        # flight) before ever recording the write - letting a test hold a
        # write "in flight" and prove close() cancels/awaits it rather than
        # racing it. None (the default) means "don't block", matching every
        # other test's normal fire-and-complete-immediately behavior.
        self._write_gate: Optional[Any] = None
        self.write_started_count = 0

    def add_value_changed(self, handler) -> int:
        token = self._next_token
        self._next_token += 1
        self._handlers[token] = handler
        return token

    def remove_value_changed(self, token: int) -> None:
        assert token in self._handlers, (
            f"remove_value_changed called with an unknown/wrong token: {token!r} "
            "(production code must remove by the exact token add_value_changed "
            "returned, not by the original callback)"
        )
        del self._handlers[token]

    async def write_client_characteristic_configuration_descriptor_async(self, value: int) -> int:
        self.cccd_history.append(value)
        return FakeGattCommunicationStatus.SUCCESS

    async def write_value_with_result_async(self, buffer: bytes) -> FakeGattWriteResult:
        assert isinstance(buffer, (bytes, bytearray)), (
            f"write_value_with_result_async must receive real bytes, got {type(buffer)!r}"
        )
        if self._write_gate is not None:
            self.write_started_count += 1
            await self._write_gate.wait()  # cancellable: a cancel() here propagates normally
        self.write_history.append(bytes(buffer))
        if self._on_write is not None:
            self._on_write(bytes(buffer))
        return FakeGattWriteResult(FakeGattCommunicationStatus.SUCCESS)

    def fire(self, payload: bytes) -> None:
        """Test helper: simulate a BLE notification arriving."""

        for handler in list(self._handlers.values()):
            handler(self, FakeEventArgs(payload))


class FakeGattDeviceService:
    _instances: Dict[str, "FakeGattDeviceService"] = {}

    def __init__(self) -> None:
        self.closed = False
        self._characteristics: Dict[uuid.UUID, FakeGattCharacteristic] = {}

    def register_characteristic(self, characteristic_uuid: uuid.UUID, characteristic) -> None:
        self._characteristics[characteristic_uuid] = characteristic

    async def get_characteristics_for_uuid_async(
        self, characteristic_uuid: uuid.UUID
    ) -> FakeGattCharacteristicsResult:
        assert isinstance(characteristic_uuid, uuid.UUID), (
            f"get_characteristics_for_uuid_async requires a uuid.UUID, got "
            f"{type(characteristic_uuid)!r}"
        )
        match = self._characteristics.get(characteristic_uuid)
        if match is None:
            return FakeGattCharacteristicsResult(FakeGattCommunicationStatus.SUCCESS, [])
        return FakeGattCharacteristicsResult(FakeGattCommunicationStatus.SUCCESS, [match])

    async def get_characteristics_with_cache_mode_async(
        self, cache_mode
    ) -> FakeGattCharacteristicsResult:
        return FakeGattCharacteristicsResult(
            FakeGattCommunicationStatus.SUCCESS, list(self._characteristics.values())
        )

    def close(self) -> None:
        self.closed = True

    @classmethod
    def get_device_selector_from_uuid(cls, service_uuid: uuid.UUID) -> str:
        """Real WinRT API this fake still models (GattDeviceService really
        does expose it) - but production code no longer calls it for
        discovery: it enumerates GATT *service-instance* paths, a different
        ID domain than BluetoothLEDevice.from_id_async() requires (XRBM-014
        review round 2 P1 #2). Kept only so tests can build a wrong-domain
        ID and assert it is rejected - see gatt_service_instance_id().
        """

        assert isinstance(service_uuid, uuid.UUID), (
            f"get_device_selector_from_uuid requires a uuid.UUID, got {type(service_uuid)!r}"
        )
        return f"AQS-selector-for-{service_uuid}"


class FakeBluetoothLEDevice:
    def __init__(self, device_id: str, service: FakeGattDeviceService) -> None:
        self.id = device_id
        self._service = service
        self.closed = False
        self._connection_status_handlers: Dict[int, Any] = {}
        self._next_token = 1
        self.connection_status = FakeBluetoothConnectionStatus.CONNECTED

    def add_connection_status_changed(self, handler) -> int:
        token = self._next_token
        self._next_token += 1
        self._connection_status_handlers[token] = handler
        return token

    def remove_connection_status_changed(self, token: int) -> None:
        assert token in self._connection_status_handlers, (
            f"remove_connection_status_changed called with an unknown/wrong token: {token!r}"
        )
        del self._connection_status_handlers[token]

    async def get_gatt_services_for_uuid_async(self, service_uuid: uuid.UUID) -> FakeGattServicesResult:
        assert isinstance(service_uuid, uuid.UUID), (
            f"get_gatt_services_for_uuid_async requires a uuid.UUID, got {type(service_uuid)!r}"
        )
        return FakeGattServicesResult(FakeGattCommunicationStatus.SUCCESS, [self._service])

    async def get_gatt_services_for_uuid_with_cache_mode_async(
        self, service_uuid: uuid.UUID, cache_mode
    ) -> FakeGattServicesResult:
        return await self.get_gatt_services_for_uuid_async(service_uuid)

    def close(self) -> None:
        self.closed = True

    def simulate_disconnect(self) -> None:
        self.connection_status = FakeBluetoothConnectionStatus.DISCONNECTED
        for handler in list(self._connection_status_handlers.values()):
            handler(self, None)


class FakeDeviceInformation:
    def __init__(self, device_id: str, name: str) -> None:
        self.id = device_id
        self.name = name


class FakeWinRTEnvironment:
    """Wires together one fake RC003 candidate + BLE device + GATT service
    with real TX/audio/control characteristics, and exposes a
    ``ble_transport_winrt.WinRTModules`` instance pointing at fake classes.
    """

    def __init__(self, device_id: str = "BluetoothLE#fake-rc003", name: str = "MI RC") -> None:
        self.device_id = device_id
        self.name = name

        from ovb_rc003 import atvv_protocol as proto

        self.tx_characteristic = FakeGattCharacteristic(uuid.UUID(proto.VOICE_TX_UUID))
        self.audio_characteristic = FakeGattCharacteristic(uuid.UUID(proto.VOICE_AUDIO_UUID))
        self.control_characteristic = FakeGattCharacteristic(uuid.UUID(proto.VOICE_CONTROL_UUID))

        self.service = FakeGattDeviceService()
        self.service.register_characteristic(uuid.UUID(proto.VOICE_TX_UUID), self.tx_characteristic)
        self.service.register_characteristic(
            uuid.UUID(proto.VOICE_AUDIO_UUID), self.audio_characteristic
        )
        self.service.register_characteristic(
            uuid.UUID(proto.VOICE_CONTROL_UUID), self.control_characteristic
        )

        self.device = FakeBluetoothLEDevice(device_id, self.service)
        self.discovered_info = FakeDeviceInformation(device_id, name)

        self._device_information_cls = self._build_device_information_cls()

    def _build_device_information_cls(self):
        discovered_info = self.discovered_info

        class _FakeDeviceInformation:
            @staticmethod
            async def find_all_async_aqs_filter(selector: str):
                # The locked 3.2.1 stubs expose the AQS-filtered overload
                # under this distinct method name (not a second positional
                # argument on the no-arg find_all_async()) - see
                # ble_transport_winrt.py's module docstring.
                assert selector == PAIRED_DEVICE_SELECTOR, (
                    f"find_all_async_aqs_filter received an unexpected selector: {selector!r}"
                )
                return [discovered_info]

        return _FakeDeviceInformation

    def _build_bluetooth_le_device_cls(self):
        device = self.device

        class _FakeBluetoothLEDeviceFactory:
            @staticmethod
            def get_device_selector_from_pairing_state(pairing_state: bool) -> str:
                assert pairing_state is True, (
                    "production code only ever discovers already-paired devices"
                )
                return PAIRED_DEVICE_SELECTOR

            @staticmethod
            async def from_id_async(device_id: str):
                # Rejects anything that is not the exact BLE-device-domain
                # ID this environment's discovery would have handed back -
                # in particular, a GATT service-instance ID (see
                # gatt_service_instance_id()) must fail here, not "happen to
                # work" (XRBM-014 review round 2 P1 #2).
                assert device_id == device.id, (
                    f"from_id_async must receive a BluetoothLEDevice-domain "
                    f"DeviceInformation.id (from get_device_selector_from_pairing_state), "
                    f"got {device_id!r} - this looks like it came from a different WinRT "
                    "ID domain (e.g. a GATT service-instance ID)"
                )
                return device

        return _FakeBluetoothLEDeviceFactory

    def build_winrt_modules(self):
        from ovb_rc003.ble_transport_winrt import WinRTModules

        return WinRTModules(
            bluetooth_le_device=self._build_bluetooth_le_device_cls(),
            bluetooth_connection_status=FakeBluetoothConnectionStatus,
            gatt_communication_status=FakeGattCommunicationStatus,
            cccd_value=FakeGattClientCharacteristicConfigurationDescriptorValue,
            device_information=self._device_information_cls,
            data_writer_factory=FakeDataWriter,
            bluetooth_cache_mode=FakeBluetoothCacheMode,
        )
