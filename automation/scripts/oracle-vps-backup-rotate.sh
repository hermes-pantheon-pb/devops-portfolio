#!/usr/bin/env bash
# ==============================================================================
# Script: oracle-vps-backup-rotate.sh
# Finalidade: Sincronização e rotação de backups multi-tier na Oracle Cloud VPS
# Destino: Backblaze B2 (Retenção Diferencial com expurgo numérico)
# ==============================================================================

set -euo pipefail

# --- CONFIGURAÇÃO GERAL ---
CRAFTY_ROOT="${CRAFTY_ROOT:-/etc/crafty/backups/a13f5bb9-98f0-4ec1-887c-0edc1728396f}"
REMOTE_ROOT="${REMOTE_ROOT:-BackblazeB2Oracle:OracleVPSBackup/Crafty}"
LOG_FILE="${LOG_FILE:-/var/log/mc_backup.log}"
RCLONE_CONFIG_PATH="${RCLONE_CONFIG_PATH:-/root/.config/rclone/rclone.conf}"

TIPO="${1:-}"

if [[ -z "${TIPO}" ]]; then
    echo "Uso: $0 [3h|daily|weekly|monthly]"
    exit 1
fi

# --- MAPEAMENTO INTELIGENTE DE RETENÇÃO ---
case "${TIPO}" in
  3h)
    LOCAL_SUBFOLDER="29cfb642-0e01-4c94-9604-311f3e1b7335"
    MAX_KEEP=8   # Retém 8 snapshots (janela de 24 horas)
    ;;
  daily)
    LOCAL_SUBFOLDER="c7061c8e-2733-4359-b474-73daba31863e"
    MAX_KEEP=4   # Retém 4 snapshots diários
    ;;
  weekly)
    LOCAL_SUBFOLDER="8caf3cbf-2d92-4b3d-acc5-1a1fea9fcc00"
    MAX_KEEP=4   # Retém 4 snapshots semanais (1 mês)
    ;;
  monthly)
    LOCAL_SUBFOLDER="694c3485-b7e3-4f70-b5cd-e1b900670fc4"
    MAX_KEEP=3   # Retém 3 snapshots mensais (1 trimestre)
    ;;
  *)
    echo "Erro: Tipo desconhecido ou não configurado: ${TIPO}"
    exit 1
    ;;
esac

# Montagem de caminhos
SRC_DIR="${CRAFTY_ROOT}/${LOCAL_SUBFOLDER}"
DEST_CURRENT="${REMOTE_ROOT}/${TIPO}/current"
DEST_ARCHIVE="${REMOTE_ROOT}/${TIPO}/archive"

echo "--- [${TIPO}] Iniciando Backup: $(date) ---" >> "${LOG_FILE}"
echo "Origem: ${SRC_DIR} -> Destino: ${DEST_CURRENT}" >> "${LOG_FILE}"

if [[ ! -d "${SRC_DIR}" ]]; then
    echo "ERRO: A pasta local ${SRC_DIR} não existe!" >> "${LOG_FILE}"
    exit 1
fi

# 1. SYNC OTIMIZADO COM BACKUP-DIR PARA HISTÓRICO
rclone sync "${SRC_DIR}" "${DEST_CURRENT}" \
    --config "${RCLONE_CONFIG_PATH}" \
    --backup-dir "${DEST_ARCHIVE}" \
    --bwlimit 15M \
    --transfers 4 \
    --min-age 2m \
    >> "${LOG_FILE}" 2>&1

# 2. ROTAÇÃO NUMÉRICA AUTOMATIZADA
echo "--- [${TIPO}] Verificando histórico remoto (Limite: ${MAX_KEEP}) ---" >> "${LOG_FILE}"

# Extrai lista ordenada por timestamp e expurga excedentes
rclone lsf "${DEST_ARCHIVE}" \
    --config "${RCLONE_CONFIG_PATH}" \
    --files-only \
    --format "tp" \
    --separator "|" | \
sort -r | \
tail -n +$((MAX_KEEP + 1)) | \
cut -d "|" -f 2 | \
while read -r FILENAME; do
  if [[ -n "${FILENAME}" ]]; then
    echo "[${TIPO}] Deletando snapshot expirado: ${FILENAME}" >> "${LOG_FILE}"
    rclone delete "${DEST_ARCHIVE}/${FILENAME}" \
        --config "${RCLONE_CONFIG_PATH}" \
        >> "${LOG_FILE}" 2>&1
  fi
done

echo "--- [${TIPO}] Concluído com sucesso: $(date) ---" >> "${LOG_FILE}"
