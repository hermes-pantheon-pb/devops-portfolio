# Arquitetura de Rede, Topologia L2/L3 e Virtualização

Este documento apresenta a especificação técnica e visual da infraestrutura de rede, detalhando a segmentação lógica sobre o hipervisor Proxmox VE, o firewall virtualizado OPNsense, o roteamento externo via OpenWrt e o controle de acesso via WireGuard.

---

## 1. Topologia Geral & Conectividade Física/Lógica

Toda a arquitetura é projetada para priorizar a **definição lógica de rede sobre a dependência física**, garantindo flexibilidade, isolamento rigoroso de zonas e segurança perimetral centralizada.

![Diagrama Visual da Topologia de Rede](./network-topology.svg)

### Diagrama de Relações e Fluxos Lógicos
```mermaid
graph TB
    subgraph WAN_ZONE ["Zona Externa & Provedor (WAN)"]
        ISP["Modem / ISP (IP Dinâmico)"]
    end

    subgraph PROXMOX_HOST ["Hipervisor Proxmox VE"]
        I340_PASSTHROUGH["NIC Física Dedicada: Intel i340-T2 (PCIe Passthrough / IOMMU)"]
        
        subgraph VM_OPNSENSE ["VM Firewall: OPNsense"]
            OPN_WAN["Porta 1 (igb0): WAN Direta (DHCP/PPPoE)"]
            OPN_DDNS["Plugin Integrado: os-ddns (Resolução Dinâmica de Endpoints)"]
            OPN_CORE["Motor de Firewall & Roteamento Inter-VLAN"]
            OPN_VTNET["Interface VirtIO Trunk (vtnet0)"]
            OPN_VLAN10["vlan01.10.0 (Tag 10 - Main_Lan / 10.10.10.0/24)"]
            OPN_VLAN20["vlan02.20.0 (Tag 20 - IoT_Lan / 10.20.20.0/24)"]
            OPN_VLAN90["vlan09.90.0 (Tag 90 - Guest_Lan / 10.90.90.0/24)"]
        end

        subgraph BRIDGES ["Infraestrutura de Bridges Linux no Proxmox"]
            M_VLAN_BR0["Bridge Tronco: M_VLAN_BR0 (VLAN-Aware)"]
            ACCESS_PORT["Linux VLAN Access Port: M_VLAN_BR0.10 (Egress Tag 10)"]
            MAIN_LAN_BR["Bridge Interna: Main_Lan (Untagged downstream)"]
            NFS_ISOLAT["Bridge Privada: nfs_isolat (Sem Router, DHCP ou DNS)"]
            VMBR0["vmbr0 (Management Host Proxmox - 10.10.10.x)"]
        end

        subgraph HARDWARE_NICS ["NICs Físicas do Servidor"]
            NIC1_REALTEK["nic1: Realtek 2.5GbE (PCIe)"]
            NIC4_I340["nic4: Intel i340 Porta Direita (Trunk Físico)"]
        end

        subgraph PROXMOX_WORKLOADS ["Workloads & Máquinas Virtuais"]
            VM_TRUSTED["MicroVMs Internas Confiáveis (Portainer, Orquestração, Apps)"]
            VM_ISOLATED["MicroVMs DMZ / Serviços Públicos"]
            VM_STORAGE["Storage VM (OpenMediaVault + MergerFS)"]
            VM_MEDIA["Media Server (SR-IOV / iGPU Passthrough)"]
        end
    end

    subgraph CLIENTS_PHYSICAL ["Dispositivos Físicos Locais"]
        MAIN_PC["Workstation Principal (Link 2.5GbE Cabeado)"]
    end

    subgraph OPENWRT_DEVICE ["Roteador / AP Wi-Fi 6 (OpenWrt - MT7981)"]
        W_TRUNK["br-vlans (Trunk 802.1Q - MTU 1504)"]
        W_V10["br-vlans.10 (10.10.10.2)"]
        W_V20["br-vlans.20 (10.20.20.156)"]
        W_V90["br-vlans.90 (10.90.90.156)"]
        
        SSID_MAIN["SSID: Pantheon & Pantheon 160MHz"]
        SSID_IOT["SSID: Pantheon_IoT"]
        SSID_GUEST["SSID: Pantheon_Convidado"]
        SSID_MNGMT["SSID: Pantheon_WRT-MNGMT"]
    end

    %% Conexões WAN
    ISP --> I340_PASSTHROUGH
    I340_PASSTHROUGH --> OPN_WAN
    OPN_WAN --- OPN_DDNS
    OPN_WAN --- OPN_CORE

    %% Conexões VLAN OPNsense
    OPN_CORE --> OPN_VTNET
    OPN_VTNET --> OPN_VLAN10
    OPN_VTNET --> OPN_VLAN20
    OPN_VTNET --> OPN_VLAN90
    OPN_VTNET <== "Trunk VirtIO" ==> M_VLAN_BR0

    %% Bridges e Portas no Proxmox
    M_VLAN_BR0 --> ACCESS_PORT
    ACCESS_PORT --> MAIN_LAN_BR
    MAIN_LAN_BR --> NIC1_REALTEK
    NIC1_REALTEK <== "2.5 Gbps Físico" ==> MAIN_PC
    MAIN_LAN_BR --> VM_TRUSTED
    MAIN_LAN_BR --> VM_MEDIA

    M_VLAN_BR0 -- "Trunk 802.1Q Físico" --> NIC4_I340
    NIC4_I340 <== "Cabo Ethernet Trunk" ==> W_TRUNK

    %% Conexão isolada para VMs públicas
    M_VLAN_BR0 -- "VLAN Tagged direto na VirtIO da VM" --> VM_ISOLATED

    %% Armazenamento Isolado
    VM_STORAGE <== "NFS Direto na Bridge nfs_isolat" ==> NFS_ISOLAT
    NFS_ISOLAT <== "Acesso Ponto-a-Ponto Seguro (Interface 2)" ==> VM_MEDIA

    %% Distribuição OpenWrt
    W_TRUNK --> W_V10 --> SSID_MAIN
    W_TRUNK --> W_V20 --> SSID_IOT
    W_TRUNK --> W_V90 --> SSID_GUEST
    W_TRUNK --> SSID_MNGMT
```

---

## 2. Detalhamento da Camada de Virtualização de Rede (Proxmox VE)

A configuração no Proxmox elimina a complexidade de configurar tags 802.1Q dentro do sistema operacional de cada máquina virtual cliente:

```
[ M_VLAN_BR0 (VLAN-Aware Bridge) ]
       │
       ├─── nic4 (Intel i340 physical port) ──> Cabo Trunk 802.1Q para o OpenWrt
       ├─── vtnet0 (VirtIO NIC da VM OPNsense) ──> Trunk para o Firewall
       │
       └─── M_VLAN_BR0.10 (Linux VLAN Access Port)
                 │  (Injeta tag 10 ao subir / remove tag 10 ao descer)
                 ▼
       [ Main_Lan (Linux Bridge) ]
            ├─── nic1 (Realtek 2.5GbE) ──> PC Principal do Usuário
            ├─── MicroVMs Confiáveis (Alpine/Debian com VirtIO simples)
            ├─── Servidor de Mídia (Jellyfin/Plex - streaming web na Main_Lan)
            └─── Containers / Portainer Workloads
```

### Por que essa arquitetura é diferenciada?
1. **Transparência para Cargas de Trabalho**: As MicroVMs, o servidor de mídia e o PC principal conectam-se à bridge `Main_Lan` sem necessidade de suporte ou configuração de VLAN no sistema operacional convidado.
2. **Políticas Forçadas no Firewall**: Qualquer pacote que precise sair da sub-rede local precisa atravessar a porta de acesso `M_VLAN_BR0.10`. Nesse momento, o Linux aplica a tag `VLAN 10` e encaminha o pacote via `M_VLAN_BR0` até a interface `vlan01.10.0` no OPNsense, onde é inspecionado, roteado ou bloqueado.
3. **Isolamento de Cargas de Risco / DMZ**: Para serviços web públicos ou agentes autônomos que demandam isolamento estrito, a interface virtual da VM é conectada diretamente à bridge `M_VLAN_BR0` com a tag de VLAN configurada no próprio Proxmox (VLAN access port por VM). Assim, o tráfego da VM nunca toca na `Main_Lan` sem antes passar pelas regras de filtragem do OPNsense.
4. **Isolamento Total do Barramento de Armazenamento (`nfs_isolat`)**: A bridge `nfs_isolat` é totalmente desconectada do firewall, não possui IP de gateway, DHCP ou DNS. Apenas a VM do OpenMediaVault e os nós autorizados (como a VM do servidor de mídia, que possui interface secundária dedicada a essa rede privada) possuem interfaces anexadas a essa bridge, garantindo zero exposição pública de armazenamento e máxima taxa de transferência.

---

## 3. Segmentação de VLANs e Zonas de Segurança

Conforme parametrizado no OPNsense e OpenWrt:

| Identificador | VLAN ID | Sub-rede IPv4 | Interface OPNsense | Interface OpenWrt | Função & Política de Acesso |
| :--- | :---: | :--- | :--- | :--- | :--- |
| **Main_Lan** | `10` | `10.10.10.0/24` | `vlan01.10.0` | `br-vlans.10` | Rede principal confiável. Acesso total a serviços internos, internet e gerência administrativa. |
| **IoT_Lan** | `20` | `10.20.20.0/24` | `vlan02.20.0` | `br-vlans.20` | Dispositivos inteligentes (Home Assistant, ESP32, smart devices). Isolados da rede principal; sem acesso à `Main_Lan`. |
| **Guest_Lan** | `90` | `10.90.90.0/24` | `vlan09.90.0` | `br-vlans.90` | Rede para convidados e visitantes. Acesso exclusivo à internet; bloqueio total contra recursos privados. |
| **Storage_Net**| N/A | Sub-rede dedicada | *Desconectado* | *Desconectado* | Bridge `nfs_isolat` no Proxmox. Compartilhamento NFS ponto-a-ponto de alta vazão sem trânsito de firewall. |

---

## 4. Roteamento Físico e Ponto de Acesso Wi-Fi 6 (OpenWrt)

A infraestrutura física externa utiliza um roteador com firmware **OpenWrt** equipado com chipset **MediaTek MT7981** (Wi-Fi 6 802.11ax), conectado via cabo Ethernet diretamente à porta `nic4` (Intel i340) do servidor Proxmox:

```mermaid
graph LR
    subgraph PROXMOX ["Servidor Proxmox"]
        NIC4["nic4 (i340 Trunk)"]
    end

    subgraph OPENWRT ["Roteador OpenWrt"]
        BR_VLANS["br-vlans (Bridge 802.1Q - MTU 1504)"]
        
        VLAN10["br-vlans.10"]
        VLAN20["br-vlans.20"]
        VLAN90["br-vlans.90"]
        
        AP_MAIN["SSID: Pantheon (2.4GHz & 5GHz 160MHz)"]
        AP_IOT["SSID: Pantheon_IoT (2.4GHz)"]
        AP_GUEST["SSID: Pantheon_Convidado (2.4GHz & 5GHz)"]
        AP_MNGMT["SSID: Pantheon_WRT-MNGMT"]
    end

    NIC4 <== "Trunk 802.1Q" ==> BR_VLANS
    BR_VLANS --> VLAN10 --> AP_MAIN
    BR_VLANS --> VLAN20 --> AP_IOT
    BR_VLANS --> VLAN90 --> AP_GUEST
    BR_VLANS --> AP_MNGMT
```

- **Mapeamento de SSIDs**: Cada rede sem fio é mapeada diretamente para a respectiva sub-interface de VLAN do OpenWrt, garantindo que celulares de visitantes ou lâmpadas inteligentes caiam automaticamente na sua zona de isolamento sem intervenção manual.
- **Rede de Gestão OpenWrt**: Uma interface dedicada (`br-mngmt` / `192.168.2.1/24`) e um SSID reservado (`Pantheon_WRT-MNGMT`) garantem acesso seguro à gerência do roteador caso ocorra qualquer indisponibilidade no trunk principal.
