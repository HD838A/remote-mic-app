#!/bin/sh
set -eu

if [ -z "${REMOTE_MIC_WINDOWS_PFX_PASSWORD:-}" ]; then
    echo "请先设置 REMOTE_MIC_WINDOWS_PFX_PASSWORD；脚本不会把密码写入文件。" >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SECRETS_DIR="$SCRIPT_DIR/secrets"
CONFIG_PATH="$SCRIPT_DIR/windows-code-signing.cnf"
KEY_PATH="$SECRETS_DIR/remote-mic-windows.key.pem"
CERT_PATH="$SECRETS_DIR/remote-mic-windows.certificate.pem"
PFX_PATH="$SECRETS_DIR/remote-mic-windows.pfx"
BASE64_PATH="$SECRETS_DIR/remote-mic-windows.pfx.base64.txt"
FINGERPRINT_PATH="$SECRETS_DIR/remote-mic-windows.certificate.sha256.txt"

umask 077
mkdir -p "$SECRETS_DIR"

if [ -e "$KEY_PATH" ] || [ -e "$CERT_PATH" ] || [ -e "$PFX_PATH" ]; then
    echo "证书文件已经存在于 $SECRETS_DIR；为避免意外轮换，脚本拒绝覆盖。" >&2
    exit 1
fi

openssl req -x509 -newkey rsa:3072 -sha256 -days 1095 \
    -config "$CONFIG_PATH" \
    -keyout "$KEY_PATH" \
    -out "$CERT_PATH" \
    -passout env:REMOTE_MIC_WINDOWS_PFX_PASSWORD

openssl pkcs12 -export \
    -inkey "$KEY_PATH" \
    -in "$CERT_PATH" \
    -name "Remote Mic Windows Release" \
    -out "$PFX_PATH" \
    -passin env:REMOTE_MIC_WINDOWS_PFX_PASSWORD \
    -passout env:REMOTE_MIC_WINDOWS_PFX_PASSWORD

openssl base64 -A -in "$PFX_PATH" -out "$BASE64_PATH"
openssl x509 -in "$CERT_PATH" -outform DER | openssl dgst -sha256 -r | awk '{print toupper($1)}' > "$FINGERPRINT_PATH"

echo "免费自签证书已经生成。"
echo "GitHub Secret WINDOWS_CERTIFICATE_PFX_BASE64：复制 $BASE64_PATH 的内容"
echo "GitHub Secret WINDOWS_CERTIFICATE_PASSWORD：使用当前环境变量的值"
echo "公开 SHA-256 证书指纹：$(cat "$FINGERPRINT_PATH")"
echo "私钥、PFX 和 Base64 文件均位于已被 gitignore 的 build/secrets/，请离线备份。"
