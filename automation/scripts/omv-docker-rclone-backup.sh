#!/usr/bin/env bash
# ==============================================================================
# Script: omv-docker-rclone-backup.sh
# Finalidade: Blueprint de backup conteinerizado efêmero gerenciado pelo OpenMediaVault.
# Executa sincronização incremental, versionada e criptografada para nuvem.
# ==============================================================================

set -euo pipefail

# Variáveis e Timestamps
TIMESTAMP=$(date +%Y-%m-%d_%H-%M)
SOURCE_POOL="${SOURCE_POOL:-/srv/mergerfs/MainSataPool}"
CONFIG_DIR="${RCLONE_CONFIG_DIR:-/docker_appdata/rclone/config}"
CACHE_DIR="${RCLONE_CACHE_DIR:-/docker_appdata/rclone/cache/cache}"
REMOTE_DEST="${REMOTE_DEST:-gdrive_crypt:backup/data/media/music/music}"
VERSION_DEST="${VERSION_DEST:-gdrive_crypt:backup/data/media/music/music-versions/${TIMESTAMP}}"

echo "Starting Rclone sync job to Google Drive (Encrypted)..."

# Execução efêmera com contêiner Docker oficial
docker run --rm \
  --user "1005:100" \
  -v "${CONFIG_DIR}:/config" \
  -v "${CACHE_DIR}:/cache" \
  -v "${SOURCE_POOL}:/data:ro" \
  -e TZ="America/Sao_Paulo" \
  -e RCLONE_CONFIG="/config/rclone.conf" \
  -e RCLONE_CACHE_DIR="/cache" \
  rclone/rclone:latest sync "/data/MSataPDataPool/data/media/music/music" "${REMOTE_DEST}" \
  --backup-dir "${VERSION_DEST}" \
  --fast-list \
  --drive-chunk-size 64M \
  --drive-stop-on-upload-limit \
  --transfers 4 \
  --checkers 8 \
  --tpslimit 10 \
  --bwlimit 30M \
  -v 2>&1 | tail -n 20

echo "Sync job completed successfully."
