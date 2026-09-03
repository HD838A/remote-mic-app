"""WinRT-based BLE transport: RC003 discovery and the ATVV GATT connection.

Windows-only. The discovery, uncached GATT connection, ATVV subscription,
capability negotiation and aggregate PCM signal path were exercised against
a real RC003 on 2026-08-22; reconnect and target-app routing remain separate
acceptance boundaries. Importing this
module never fails without the optional ``winrt-Windows.*`` packages
installed; only calling its async functions does, with a clear error.

Dependency closure (XRBM-024): ``discover_candidates()``'s
``find_all_async_aqs_filter()`` call returns a
``Windows.Foundation.IAsyncOperation``, and iterating the resulting
``DeviceInformationCollection`` uses a ``Windows.Foundation.Collections``
``IIterator`` - both projections are exact ``3.2.1`` pins in
requirements.txt and PyInstaller hidden imports even though this module
never imports either module by name (see ``_import_winrt()``, which
imports both explicitly purely to turn a missing pin into this module's own
``WinRTUnavailableError`` instead of a raw ``ModuleNotFoundError`` from
inside an awaited coroutine).

WinRT call surface (fixed after XRBM-014 review RETRY P1 #1, and again after
review round 2 P1 #2 - see XRBM-014's independent review): every
call below is written to match the locked ``winrt-Windows.*==3.2.1``
Python projection's actual signatures rather than the earlier,
deterministically-wrong drafts:

- Discovery uses ``BluetoothLEDevice.get_device_selector_from_pairing_state(True)``
  (a synchronous static method on ``BluetoothLEDevice``, not
  ``GattDeviceService``) passed to
  ``DeviceInformation.find_all_async_aqs_filter(selector)`` (the locked
  3.2.1 stubs expose the AQS-filtered overload under this distinct method
  name, not as a second positional argument on the no-arg
  ``find_all_async()``). This is the fix for round 2 P1 #2: the previous
  draft got a ``DeviceInformation.id`` from
  ``GattDeviceService.get_device_selector_from_uuid()``, which enumerates
  GATT *service-instance* paths - a different WinRT ID domain from the BLE
  *device* ID ``BluetoothLEDevice.from_id_async()`` requires. Every
  ``DeviceInformation.id`` this module ever calls ``from_id_async`` with now
  comes exclusively from the paired-BLE-device selector.
- After ``from_id_async`` opens the device, ``connect()`` still calls
  ``get_gatt_services_for_uuid_async`` for the ATVV voice service UUID and
  raises if it is absent - this is the "verify the ATVV service after
  opening" half of the same fix: a device that happens to answer
  ``from_id_async`` but does not expose the ATVV service is rejected here,
  not assumed compatible just because discovery found it.
- Every GATT UUID is converted to ``uuid.UUID`` before being passed to
  ``get_gatt_services_for_uuid_async``/``get_characteristics_for_uuid_async``
  - the projection requires a real ``uuid.UUID``, not a string.
- ``write_value_with_result_async`` returns a ``GattWriteResult`` object;
  its ``.status`` attribute is compared to ``GattCommunicationStatus``, not
  the result object itself.
- Notification subscriptions are tracked by the ``EventRegistrationToken``
  that ``add_value_changed``/``add_connection_status_changed`` return, and
  cleanup calls ``remove_value_changed``/``remove_connection_status_changed``
  with that exact token - not with the original callback.
- ``close()`` writes the CCCD value back to ``NONE`` on both subscribed
  characteristics, removes both notification handlers and the connection-
  status handler by token, then closes the ``GattDeviceService`` and the
  ``BluetoothLEDevice`` (both implement ``IClosable``).
- ``BluetoothLEDevice.add_connection_status_changed`` is wired so a real
  disconnect is observed and reported via ``on_disconnected`` instead of the
  session silently waiting forever - see connection_supervisor.py for how
  app.py turns that into a reconnect.

These signatures match the locked wheel's ``.pyi`` stubs and the real-device
connection described above. tests/test_ble_transport_contract.py
exercises this module's call shape (method names, argument types, token
plumbing) against an in-repo fake WinRT projection that mimics the same
signatures, so at least internal consistency is covered by an automated,
cross-platform test - not a substitute for real-hardware verification, but
not nothing either.

Threading/blocking (XRBM-014 review RETRY P1 #4 / P2 audio threading): the
notification callbacks WinRT invokes (``_handle_control_notification``,
``_handle_audio_notification``) do nothing but a non-blocking, bounded,
drop-oldest-on-full queue push. A single dedicated worker thread (not the
thread WinRT invoked the callback on) pulls from that queue, decodes ATVV
audio/control frames through the (single-threaded-by-design)
``atvv_session.ATVVSession``, and forwards results to ``on_pcm_frame``/
``on_control_event``. Queued items are tagged with a per-``connect()``
generation counter; the worker drops any item whose generation doesn't
match the current one, so audio/control events queued by a previous,
already-torn-down session can never be processed after a reconnect.
"""

from __future__ import annotations

import asyncio
import queue
import threading
import uuid
from dataclasses import dataclass
from typing import Any, Callable, List, Optional

from . import atvv_protocol as proto
from . import atvv_session
from . import identity

PcmCallback = Callable[[List[int]], None]
ControlEventCallback = Callable[[object], None]
ErrorCallback = Callable[[BaseException], None]
DisconnectedCallback = Callable[[], None]

_QUEUE_MAXSIZE = 64
_WORKER_POLL_SECONDS = 0.2


class WinRTUnavailableError(Exception):
    """Raised when the optional winrt Bluetooth packages are not installed."""


@dataclass(frozen=True)
class WinRTModules:
    """Everything ble_transport_winrt.py needs from the winrt packages,
    grouped so tests can inject an in-memory fake implementing the same
    call shape instead of requiring the real packages to be installed.
    """

    bluetooth_le_device: Any
    bluetooth_connection_status: Any
    gatt_communication_status: Any
    cccd_value: Any
    device_information: Any
    data_writer_factory: Callable[[], Any]
    bluetooth_cache_mode: Any


def _import_winrt() -> WinRTModules:
    try:
        from winrt.windows.devices.bluetooth import (
            BluetoothCacheMode,
            BluetoothConnectionStatus,
            BluetoothLEDevice,
        )
        from winrt.windows.devices.bluetooth.genericattributeprofile import (
            GattClientCharacteristicConfigurationDescriptorValue,
            GattCommunicationStatus,
        )
        from winrt.windows.devices.enumeration import DeviceInformation
        from winrt.windows.storage.streams import DataWriter

        # XRBM-024: not referenced by name anywhere below - discovered only
        # when a real WinRT call is awaited (DeviceInformation.find_all_
        # async_aqs_filter() returns a Windows.Foundation.IAsyncOperation;
        # iterating its result uses a Windows.Foundation.Collections
        # IIterator) - so importing them here, up front, turns a missing
        # projection into this function's clean WinRTUnavailableError
        # instead of a raw ModuleNotFoundError surfacing deep inside an
        # awaited coroutine (see requirements.txt's XRBM-024 comment for the
        # exact red evidence this closes).
        import winrt.windows.foundation  # noqa: F401
        import winrt.windows.foundation.collections  # noqa: F401
    except ImportError as exc:  # pragma: no cover - exercised only on Windows
        raise WinRTUnavailableError(
            "winrt Bluetooth packages are not installed; install "
            "requirements.txt inside a Windows virtual environment"
        ) from exc
    return WinRTModules(
        bluetooth_le_device=BluetoothLEDevice,
        bluetooth_connection_status=BluetoothConnectionStatus,
        gatt_communication_status=GattCommunicationStatus,
        cccd_value=GattClientCharacteristicConfigurationDescriptorValue,
        device_information=DeviceInformation,
        data_writer_factory=DataWriter,
        bluetooth_cache_mode=BluetoothCacheMode,
    )


async def discover_candidates(
    winrt: Optional[WinRTModules] = None,
) -> List[identity.RC003Candidate]:
    """Enumerate currently-paired BLE devices.

    Each returned candidate's ``handle`` is the WinRT ``DeviceInformation``
    object needed to connect; nothing about the device is persisted here.

    Uses ``BluetoothLEDevice.get_device_selector_from_pairing_state(True)``
    (XRBM-018, fixing XRBM-014 review round 2 P1 #2) so every
    ``DeviceInformation.id`` returned here is a genuine BLE-device-domain ID
    - the only kind ``BluetoothLEDevice.from_id_async()`` in ``connect()``
    below is ever called with. Identity here is otherwise by exact
    advertised/paired name only (see identity.py); there is no HID VID/PID
    signal available at the BLE layer (unlike raw_input_windows.py, which
    filters by a real VID/PID-bearing device path).
    """

    winrt = winrt or _import_winrt()

    selector = winrt.bluetooth_le_device.get_device_selector_from_pairing_state(True)
    devices = await winrt.device_information.find_all_async_aqs_filter(selector)

    candidates: List[identity.RC003Candidate] = []
    for info in devices:
        name = getattr(info, "name", "") or ""
        candidates.append(
            identity.RC003Candidate(name=name, hardware_match=False, handle=info)
        )
    return candidates


class RC003BleSession:
    """One BLE GATT connection to a chosen RC003 candidate."""

    def __init__(
        self,
        on_pcm_frame: PcmCallback,
        on_control_event: Optional[ControlEventCallback] = None,
        on_error: Optional[ErrorCallback] = None,
        on_disconnected: Optional[DisconnectedCallback] = None,
        gain_db: float = 10.0,
        winrt: Optional[WinRTModules] = None,
        loop: Optional[asyncio.AbstractEventLoop] = None,
    ) -> None:
        self._on_pcm_frame = on_pcm_frame
        self._on_control_event = on_control_event
        self._on_error = on_error
        self._on_disconnected = on_disconnected
        self._session = atvv_session.ATVVSession(gain_db=gain_db)
        self._winrt = winrt
        self._device = None
        self._service = None
        self._tx_characteristic = None
        self._audio_characteristic = None
        self._control_characteristic = None
        self._audio_token = None
        self._control_token = None
        self._connection_status_token = None
        # WinRT notification callbacks are not guaranteed to run on the
        # asyncio thread that owns connect()/close(); this loop reference
        # lets send_mic_open_threadsafe() hop back onto it safely.
        self._loop = loop or asyncio.get_event_loop()

        self._generation = 0
        self._event_queue: "queue.Queue[tuple]" = queue.Queue(maxsize=_QUEUE_MAXSIZE)
        self._worker_thread: Optional[threading.Thread] = None
        self._worker_stop = threading.Event()
        self.dropped_event_count = 0
        # Gates send_mic_open_threadsafe()'s scheduled write - see that
        # method's docstring.
        self._closing = False
        # Every MIC_OPEN write task send_mic_open_threadsafe() schedules,
        # tracked so close() can cancel/await any still in-flight one before
        # touching GATT resources (XRBM-018 RETRY 1 P1 #3) - see
        # _cancel_pending_mic_open_writes().
        self._mic_open_tasks: "set[asyncio.Task]" = set()

    @property
    def session(self) -> atvv_session.ATVVSession:
        return self._session

    async def connect(self, candidate: identity.RC003Candidate) -> None:
        winrt = self._winrt or _import_winrt()
        self._winrt = winrt

        self._generation += 1
        my_generation = self._generation

        self._device = await winrt.bluetooth_le_device.from_id_async(candidate.handle.id)
        if self._device is None:
            raise ConnectionError("could not open the selected RC003 candidate")

        self._connection_status_token = self._device.add_connection_status_changed(
            self._handle_connection_status_changed
        )

        service_uuid = uuid.UUID(proto.VOICE_SERVICE_UUID)
        # Windows caches the GATT table per device; a stale or incomplete
        # cache can hide the ATVV characteristics that this app must read
        # (observed as "ATVV characteristic not found"). Query the service
        # and characteristics with UNCACHED so the device is re-read on the
        # wire instead of trusting the local cache, matching the upstream
        # remote-bridge-hub transport.
        service_result = await self._device.get_gatt_services_for_uuid_with_cache_mode_async(
            service_uuid, winrt.bluetooth_cache_mode.UNCACHED
        )
        if (
            service_result.status != winrt.gatt_communication_status.SUCCESS
            or not service_result.services
        ):
            raise ConnectionError("ATVV voice service not found on this device")
        self._service = service_result.services[0]

        self._tx_characteristic = await self._require_characteristic(
            self._service, proto.VOICE_TX_UUID, winrt
        )
        self._audio_characteristic = await self._require_characteristic(
            self._service, proto.VOICE_AUDIO_UUID, winrt
        )
        self._control_characteristic = await self._require_characteristic(
            self._service, proto.VOICE_CONTROL_UUID, winrt
        )

        self._audio_token = self._audio_characteristic.add_value_changed(
            self._handle_audio_notification
        )
        self._control_token = self._control_characteristic.add_value_changed(
            self._handle_control_notification
        )

        for characteristic in (self._audio_characteristic, self._control_characteristic):
            subscribe_status = await characteristic.write_client_characteristic_configuration_descriptor_async(  # noqa: E501
                winrt.cccd_value.NOTIFY
            )
            if subscribe_status != winrt.gatt_communication_status.SUCCESS:
                raise ConnectionError(
                    f"subscribing to notifications failed: {subscribe_status}"
                )

        self._start_worker(my_generation)
        await self._write_tx(proto.GET_CAPABILITIES_V10)

    @staticmethod
    async def _require_characteristic(service, characteristic_uuid: str, winrt: WinRTModules):
        parsed_uuid = uuid.UUID(characteristic_uuid)
        # Enumerate the service's full characteristic table with UNCACHED
        # (the exact-UUID lookup can return an empty/unsuccessful result when
        # the per-service GATT cache is incomplete) and match on the UUID.
        result = await service.get_characteristics_with_cache_mode_async(
            winrt.bluetooth_cache_mode.UNCACHED
        )
        if result.status != winrt.gatt_communication_status.SUCCESS:
            raise ConnectionError(f"ATVV characteristic not found: {characteristic_uuid}")
        for characteristic in result.characteristics:
            if str(characteristic.uuid).casefold() == str(parsed_uuid).casefold():
                return characteristic
        raise ConnectionError(f"ATVV characteristic not found: {characteristic_uuid}")

    async def _write_tx(self, data: bytes) -> None:
        winrt = self._winrt or _import_winrt()
        writer = winrt.data_writer_factory()
        writer.write_bytes(bytes(data))
        result = await self._tx_characteristic.write_value_with_result_async(
            writer.detach_buffer()
        )
        if result.status != winrt.gatt_communication_status.SUCCESS:
            raise ConnectionError(
                f"writing to ATVV TX characteristic failed: {result.status}"
            )

    def send_mic_open_threadsafe(self) -> None:
        """Schedule the mic-open write from any thread (see __init__ note).

        Generation/closing gate (XRBM-018 DoD 4): the write is scheduled
        with the generation current *at call time*; by the time it actually
        runs on the loop thread, close() may already have started tearing
        this session down (or a reconnect may already have started a fresh
        one) - the scheduled callback re-checks both ``self._closing`` and
        that the generation has not moved on before ever touching
        ``self._tx_characteristic``, so a stale write can never land on an
        already-closing/superseded session.

        Task tracking (XRBM-018 RETRY 1 P1 #3): the write task is stored in
        ``self._mic_open_tasks`` for as long as it is pending, so
        ``close()`` can cancel and await any write that is already in
        flight - not merely one that hasn't started yet - before it ever
        touches GATT resources (MIC_CLOSE, CCCD, characteristic/service/
        device disposal). The earlier version only checked the gate
        *before* scheduling; once a write had actually started, nothing
        stopped it from completing concurrently with (or after) teardown.

        Any write failure that does make it through is observed via
        ``add_done_callback`` and reported through ``on_error`` (never
        silently dropped as an un-awaited, fire-and-forget task would),
        which is what lets app.py's reconnect-on-error path actually see
        it.
        """

        generation = self._generation

        def _schedule() -> None:
            if self._closing or generation != self._generation:
                return
            task = asyncio.ensure_future(self._write_tx(self._session.mic_open_command()))
            self._mic_open_tasks.add(task)
            task.add_done_callback(lambda t: self._on_mic_open_task_done(t, generation))

        self._loop.call_soon_threadsafe(_schedule)

    def _on_mic_open_task_done(self, task: "asyncio.Task", generation: int) -> None:
        self._mic_open_tasks.discard(task)
        self._observe_mic_open_result(task, generation)

    def _observe_mic_open_result(self, future: "asyncio.Future", generation: int) -> None:
        if future.cancelled():
            return
        exc = future.exception()
        if exc is None:
            return
        if self._closing or generation != self._generation:
            return  # a torn-down/superseded session's error is not actionable
        if self._on_error is not None:
            self._on_error(exc)

    async def _cancel_pending_mic_open_writes(self) -> None:
        """Cancels and awaits every MIC_OPEN write task
        send_mic_open_threadsafe() scheduled that has not finished yet, so
        an already-in-flight WinRT write can never complete concurrently
        with (or after) the GATT teardown close() performs next (XRBM-018
        RETRY 1 P1 #3).

        Every outcome (result, exception, or cancellation) is awaited here,
        so no "Task exception was never retrieved" warning can ever surface
        for a write this raced with - each task's own done-callback
        (``_on_mic_open_task_done``/``_observe_mic_open_result``) already
        independently observes/reports genuine failures; this method's own
        ``try/except`` around each ``await`` exists only so a cancellation
        (or a failure that races the same task) can never propagate out of
        close() itself.
        """

        tasks = list(self._mic_open_tasks)
        for task in tasks:
            task.cancel()
        for task in tasks:
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        self._mic_open_tasks.clear()

    # -- notification callbacks: non-blocking enqueue only -----------------

    def _handle_control_notification(self, _sender, args) -> None:
        self._enqueue("control", bytes(args.characteristic_value))

    def _handle_audio_notification(self, _sender, args) -> None:
        self._enqueue("audio", bytes(args.characteristic_value))

    def _handle_connection_status_changed(self, sender, _args) -> None:
        winrt = self._winrt
        try:
            disconnected = (
                sender.connection_status == winrt.bluetooth_connection_status.DISCONNECTED
            )
        except Exception:  # noqa: BLE001 - treat any read failure as "assume disconnected"
            disconnected = True
        if disconnected and self._on_disconnected is not None:
            self._on_disconnected()

    def _enqueue(self, kind: str, payload: bytes) -> None:
        item = (self._generation, kind, payload)
        try:
            self._event_queue.put_nowait(item)
        except queue.Full:
            try:
                self._event_queue.get_nowait()  # drop oldest
            except queue.Empty:
                pass
            self.dropped_event_count += 1
            try:
                self._event_queue.put_nowait(item)
            except queue.Full:
                pass

    # -- dedicated worker thread: decode + dispatch, never on a WinRT thread

    def _start_worker(self, generation: int) -> None:
        self._worker_stop.clear()
        self._worker_thread = threading.Thread(
            target=self._worker_loop, args=(generation,), daemon=True
        )
        self._worker_thread.start()

    def _worker_loop(self, generation: int) -> None:
        while not self._worker_stop.is_set():
            try:
                item_generation, kind, payload = self._event_queue.get(
                    timeout=_WORKER_POLL_SECONDS
                )
            except queue.Empty:
                continue
            if item_generation != generation:
                continue  # stale event from a previous/torn-down session
            if kind == "control":
                self._process_control(payload)
            elif kind == "audio":
                self._process_audio(payload)

    def _process_control(self, payload: bytes) -> None:
        try:
            event = self._session.handle_control(payload)
        except atvv_session.ATVVProtocolError as exc:
            if self._on_error is not None:
                self._on_error(exc)
            return
        if self._on_control_event is not None:
            self._on_control_event(event)

    def _process_audio(self, payload: bytes) -> None:
        samples = self._session.handle_audio(payload)
        if samples:
            self._on_pcm_frame(samples)

    async def close(self) -> None:
        """Closes the BLE session, always attempting every independent
        cleanup step regardless of any single step's outcome, then raises
        if the worker thread never actually stopped (XRBM-019 P1 #3 - see
        XRBM-018's independent review round 2 finding #2, which
        found the prior "report a join timeout via on_error and keep
        going" behavior let ``app.py``'s cleanup silently drop the session
        owner over a still-live worker thread anyway).

        A worker-thread join timeout is now a real ``close()`` failure: it
        is tracked but does NOT short-circuit the method - every other
        independent GATT cleanup step below (MIC_CLOSE write, CCCD
        removal, event-token cleanup, service/device close) still runs -
        and only once all of them have been attempted does this raise,
        with ``self._worker_thread`` deliberately left set (never cleared
        to ``None``) so a caller can observe the still-live thread instead
        of it being silently forgotten.
        """

        # Set before anything else (and synchronously, on the loop thread
        # this coroutine runs on) so any send_mic_open_threadsafe() callback
        # already queued via call_soon_threadsafe sees it the moment it runs.
        self._closing = True
        # Then, before anything else touches GATT resources: cancel/await
        # any MIC_OPEN write that is already in flight (XRBM-018 RETRY 1 P1
        # #3) - closing the gate above only stops *new* writes from being
        # scheduled, it does nothing about one that had already started.
        await self._cancel_pending_mic_open_writes()

        worker_join_failed = False
        self._worker_stop.set()
        if self._worker_thread is not None:
            self._worker_thread.join(timeout=2.0)
            if self._worker_thread.is_alive():
                worker_join_failed = True
            else:
                self._worker_thread = None
        while True:  # drain so a future restart never replays stale events
            try:
                self._event_queue.get_nowait()
            except queue.Empty:
                break

        if self._session.mic_open:
            try:
                await self._write_tx(self._session.mic_close_command())
            except Exception:
                # A MIC_CLOSE write failure must never abort the rest of
                # this method (XRBM-018 RETRY 1 item 6): unsubscribe/
                # service/device cleanup below still has to run regardless
                # of what kind of exception this raised (not only
                # ConnectionError - the underlying WinRT call itself could
                # raise something else entirely).
                pass

        winrt = self._winrt
        if winrt is not None:
            if self._audio_characteristic is not None:
                try:
                    await self._audio_characteristic.write_client_characteristic_configuration_descriptor_async(  # noqa: E501
                        winrt.cccd_value.NONE
                    )
                except Exception:
                    pass
                if self._audio_token is not None:
                    try:
                        self._audio_characteristic.remove_value_changed(self._audio_token)
                    except Exception:
                        pass
            if self._control_characteristic is not None:
                try:
                    await self._control_characteristic.write_client_characteristic_configuration_descriptor_async(  # noqa: E501
                        winrt.cccd_value.NONE
                    )
                except Exception:
                    pass
                if self._control_token is not None:
                    try:
                        self._control_characteristic.remove_value_changed(self._control_token)
                    except Exception:
                        pass
            if self._device is not None and self._connection_status_token is not None:
                try:
                    self._device.remove_connection_status_changed(
                        self._connection_status_token
                    )
                except Exception:
                    pass

        if self._service is not None:
            try:
                self._service.close()
            except Exception:
                pass
            self._service = None
        if self._device is not None:
            try:
                self._device.close()
            except Exception:
                pass
            self._device = None

        self._tx_characteristic = None
        self._audio_characteristic = None
        self._control_characteristic = None
        self._audio_token = None
        self._control_token = None
        self._connection_status_token = None

        if worker_join_failed:
            # Raised only now, after every independent GATT cleanup step
            # above has already been attempted - see the method docstring.
            raise RuntimeError(
                "ATVV worker thread did not stop within close()'s join "
                "timeout; the BLE session owner must be retained, not "
                "dropped, and no reconnect may start a replacement "
                "generation over it"
            )
