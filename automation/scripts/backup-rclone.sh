#!/usr/bin/env bash
# ==============================================================================
# Script: backup-rclone.sh
# Finalidade: Sincronização automatizada e criptografada de backups para nuvem
# Providers compatíveis: Backblaze B2, Hetzner Storage Box, Google Drive
# ==============================================================================

set -euo pipefail

# Configurações de Caminho e Destino
SOURCE_DIR="${BACKUP_SOURCE:-/mnt/storage/backups/critical}"
REMOTE_TARGET="${BACKUP_REMOTE:-b2-crypt:secure-backups/cluster}"
LOG_FILE="${BACKUP_LOG:-/var/log/backup-rclone.log}"

# Funções Auxiliares de Logging
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "${LOG_FILE}"
}

# Verificações Iniciais
if [[ ! -d "${SOURCE_DIR}" ]]; then
    log "ERROR" "Diretório de origem não encontrado: ${SOURCE_DIR}"
    exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
    log "ERROR" "Binário rclone não instalado ou não disponível no PATH."
    exit 1
fi

log "INFO" "Iniciando rotina de sincronização de: ${SOURCE_DIR} -> ${REMOTE_TARGET}"

# Execução do rclone com controle de concorrência, retries e criptografia ponta a ponta
START_TIME=$(date +%s)

# Notificação por E-mail (se MAIL_TO estiver definido)
ADMIN_EMAIL="${BACKUP_ALERT_EMAIL:-}"

notify_admin() {
    local subject="$1"
    local message="$2"
    if [[ -n "${ADMIN_EMAIL}" ]] && command -v mail >/dev/null 2>&1; then
        echo -e "${message}" | mail -s "${subject}" "${ADMIN_EMAIL}" || true
    fi
}

if rclone sync "${SOURCE_DIR}" "${REMOTE_TARGET}" \
    --fast-list \
    --transfers=4 \
    --checkers=8 \
    --retries=3 \
    --low-level-retries=10 \
    --stats=1m \
    --stats-one-line \
    --log-file="${LOG_FILE}" \
    --log-level="NOTICE"; then
    
    DURATION=$(( $(date +%s) - START_TIME ))
    log "INFO" "Sincronização concluída com sucesso em ${DURATION} segundos."
    notify_admin "[SUCCESS] Backup Concluído: ${REMOTE_TARGET}" \
        "Backup finalizado com sucesso em ${DURATION} segundos.\nOrigem: ${SOURCE_DIR}\nDestino: ${REMOTE_TARGET}\nLog: ${LOG_FILE}"
else
    STATUS=$?
    log "ERROR" "Falha na sincronização do rclone com código de saída: ${STATUS}"
    notify_admin "[CRITICAL] Falha no Backup: ${REMOTE_TARGET}" \
        "Erro na rotina de sincronização (Exit Code: ${STATUS}).\nConsulte o log: ${LOG_FILE}\nOrigem: ${SOURCE_DIR}"
    exit "${STATUS}"
fi
