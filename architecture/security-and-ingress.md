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
    participant FW as OPNsense / Local Firewall
    participant SVC as Serviço Interno (MicroVM / Docker)

    Note over FW,WG: O cluster local inicia e mantém o túnel WireGuard ativo para a VPS da Oracle.<br/>Nenhuma porta de entrada (Inbound) é aberta no roteador residencial!

    User->>OCI: Acesso HTTPS (ex: app.dominio.com)
    OCI->>NGINX: Recebe na porta 443 com certificado Let's Encrypt
    NGINX->>User: Exige desafio de autenticação (2FA / Sessão Segura)
    User->>NGINX: Fornece credencial + Token 2FA
    NGINX->>WG: Encaminha tráfego autenticado pelo túnel WireGuard (10.100.0.x)
    WG->>FW: Tráfego entra pela interface virtual do WireGuard
    FW->>SVC: Regra de firewall encaminha para o contêiner interno
    SVC-->>User: Retorna resposta criptografada ponta a ponta
```

---

## 2. Princípios de Segurança Aplicados

### 1. Zero Inbound Ports na WAN Residencial
Em vez de expor o IP público dinâmico da residência com port-forwarding no roteador (o que atrai varreduras automatizadas de bots, ataques DDoS e tentativas de brute-force), a infraestrutura adota uma **Oracle Cloud VPS** como bastion host / edge proxy:
- A conexão WireGuard é originada de dentro da rede local em direção ao IP fixo da Oracle Cloud (túnel persistente de saída).
- Firewalls perimetrais residenciais mantêm políticas de `DROP` irrestritas para conexões inbound da WAN.

### 2. Autenticação e Proxy Reverso com Defesa em Camadas
- **Nginx Reverse Proxy**: Gerencia terminação TLS com certificados modernos, cifras seguras e cabeçalhos de proteção (`HSTS`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`).
- **Autenticação em Dois Fatores (2FA)**: Interfaces administrativas críticas (como o painel do servidor Minecraft ou consoles de gerenciamento) possuem camada obrigatória de autenticação multifator antes de qualquer exposição de backend.

### 3. Hardening e Privilégios Mínimos em Contêineres
- Ativação do parâmetro `no-new-privileges: true` em todos os contêineres gerenciados.
- Execução com usuários não-root mapeados (`PUID/PGID: 1000:1000`).
- Sistemas de arquivos de configuração montados como Read-Only (`:ro`) onde a escrita não é estritamente mandatória.
- Limites rigorosos de recursos declarados (`deploy.resources.limits` para CPU e RAM) para prevenir degradação por esgotamento de recursos (*noisy neighbors*).
