# Arquitetura de Ingress Seguro e Nuvem Híbrida

Este documento detalha o modelo de publicação de serviços na internet sem abertura de portas residenciais (Zero Inbound Port Forwarding), integrando instâncias públicas na Oracle Cloud Infrastructure (OCI) ao homelab local.

---

## 1. Fluxo de Publicação e Ingress Clientless

```mermaid
sequenceDiagram
    autonumber
    actor User as Usuário Externo (Web/Mobile)
    participant OCI as Oracle Cloud VPS (Edge Gateway)
    participant NGINX as Nginx Reverse Proxy (SSL + 2FA)
    participant WG as Túnel WireGuard (Outbound Only)
    participant GLUETUN as Cliente WireGuard / Gluetun (Container/VM)
    participant SVC as Serviço Interno (Aplicação / Backend)

    Note over GLUETUN,WG: O contêiner/VM local (normalmente via Gluetun) inicia e mantém o túnel WireGuard de saída direto para a VPS da Oracle.<br/>O tráfego NÃO termina no OPNsense nem requer abertura de portas locais!

    User->>OCI: Acesso HTTPS (ex: app.dominio.com)
    OCI->>NGINX: Recebe na porta 443 com certificado Let's Encrypt
    NGINX->>User: Exige desafio de autenticação (2FA / Sessão Segura)
    User->>NGINX: Fornece credencial + Token 2FA
    NGINX->>WG: Encaminha tráfego autenticado pelo túnel WireGuard (10.100.0.x)
    WG->>GLUETUN: Tráfego chega diretamente ao contêiner Gluetun / interface WireGuard do serviço
    GLUETUN->>SVC: Roteamento local direto para a aplicação (localhost / network_mode: service:gluetun)
    SVC-->>User: Retorna resposta criptografada ponta a ponta
```

---

## 2. Princípios de Segurança Aplicados

### 1. Zero Inbound Ports na WAN Residencial & Isolamento por Contêiner
Em vez de expor o IP público dinâmico da residência com port-forwarding no roteador ou terminar o túnel no firewall OPNsense:
- A conexão WireGuard é originada de dentro da rede local diretamente pelos contêineres e VMs que necessitam de exposição pública (usualmente encapsulado via contêiner VPN **Gluetun** como sidecar de rede).
- O firewall perimetral OPNsense apenas atua como roteador transparente de tráfego de saída (outbound UDP), sem intermediar nem decodificar o Ingress.
- Políticas de `DROP` irrestritas são mantidas para conexões inbound da WAN na rede residencial.

### 2. Autenticação e Proxy Reverso com Defesa em Camadas
- **Nginx Reverse Proxy**: Gerencia terminação TLS com certificados modernos, cifras seguras e cabeçalhos de proteção (`HSTS`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`).
- **Autenticação em Dois Fatores (2FA)**: Interfaces administrativas críticas (como o painel do servidor Minecraft ou consoles de gerenciamento) possuem camada obrigatória de autenticação multifator antes de qualquer exposição de backend.

### 3. Hardening e Privilégios Mínimos em Contêineres
- Ativação do parâmetro `no-new-privileges: true` em todos os contêineres gerenciados.
- Execução com usuários não-root mapeados (`PUID/PGID: 1000:1000`).
- Sistemas de arquivos de configuração montados como Read-Only (`:ro`) onde a escrita não é estritamente mandatória.
- Limites rigorosos de recursos declarados (`deploy.resources.limits` para CPU e RAM) para prevenir degradação por esgotamento de recursos (*noisy neighbors*).
