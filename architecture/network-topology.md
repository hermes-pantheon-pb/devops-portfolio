# Arquitetura de Rede e Segmentação L2/L3

Este documento detalha o modelo de conectividade, virtualização de rede e segurança perimetral implementado no ambiente de infraestrutura.

---

## 1. Topologia de Rede & Virtualização

```mermaid
graph TB
    subgraph WAN ["Internet Pública & Provedor"]
        ISP["Modem / ISP (IP Dinâmico)"]
        DDNS["Provedor DDNS (Atualização Automática)"]
    end

    subgraph PROXMOX ["Hipervisor Proxmox VE"]
        PHY_NIC1["NIC Física 1 (PCI Passthrough / IOMMU)"]
        PHY_NIC2["NIC Física 2 (Trunk 802.1Q)"]
        
        subgraph VROUTER ["VM: OPNsense (Firewall Perimetral)"]
            FW_WAN["Interface WAN (DHCP/PPPoE)"]
            FW_CORE["Regras de Firewall, NAT & WireGuard"]
            FW_LAN["Interface LAN (VirtIO Trunk VLANs)"]
        end

        VMBR0["Linux Bridge vmbr0 (VLAN-Aware)"]
        VMBR1["Linux Bridge vmbr1 (Downstream Access Port)"]
        VMBR_STOR["Linux Bridge Isolada vmbr_storage (No-Routing / Direct)"]

        subgraph VMS ["Workloads & MicroVMs"]
            VM_WEB["MicroVM Web Services (VLAN 10 - DMZ)"]
            VM_APPS["MicroVM Alpine Orquestração & Containers (VLAN 20)"]
            VM_MEDIA["MicroVM Media Server com iGPU Passthrough (VLAN 20)"]
            VM_STORAGE["Storage VM (OMV + MergerFS + HBA Passthrough)"]
        end
    end

    subgraph SOHO ["Infraestrutura Física Externa"]
        MANAGED_SW["Switch Gerenciado / Roteador OpenWrt"]
        WIFI_CORP["SSID Interno (VLAN 20)"]
        WIFI_GUEST["SSID Visitantes (VLAN 30)"]
        WIFI_IOT["SSID IoT (VLAN 30 - Isolado)"]
    end

    ISP --> PHY_NIC1
    PHY_NIC1 --> FW_WAN
    FW_WAN <--> DDNS
    FW_CORE --- FW_WAN
    FW_CORE --- FW_LAN
    FW_LAN --> VMBR0

    VMBR0 -- "VLAN 10 Tagged" --> VM_WEB
    VMBR0 -- "VLAN 20 Tagged" --> VMBR1
    VMBR1 --> VM_APPS
    VMBR1 --> VM_MEDIA
    
    VMBR0 -- "Trunk 802.1Q" --> PHY_NIC2
    PHY_NIC2 --> MANAGED_SW
    MANAGED_SW --> WIFI_CORP
    MANAGED_SW --> WIFI_GUEST
    MANAGED_SW --> WIFI_IOT

    VM_STORAGE <== "NFS/SMB Direto (Sem Roteamento)" ==> VMBR_STOR
    VMBR_STOR <== "Alta Largura de Banda / Isolamento" ==> VM_MEDIA
```

---

## 2. Segmentação de VLANs e Políticas de Controle

A rede é particionada em zonas de confiança estritas controladas centralmente pelo firewall virtualizado OPNsense:

| VLAN ID | Nome da Zona | Finalidade | Política de Encaminhamento |
| :--- | :--- | :--- | :--- |
| **VLAN 10** | `DMZ_PUBLIC` | Serviços destinados à publicação externa | Bloqueio padrão para qualquer tráfego interno (VLAN 20/40); acesso restrito à WAN. |
| **VLAN 20** | `INTERNAL_WORKLOADS` | MicroVMs Alpine, Portainer, Game Servers, Media Stacks | Comunicação interna permitida; acesso à internet filtrado por DNS seguro e firewall. |
| **VLAN 30** | `GUEST_IOT` | Dispositivos inteligentes (Home Assistant/ESP32) e visitantes | Isolamento L2 entre clientes (*client isolation*); bloqueio total de tráfego para a VLAN 20. |
| **Isolada** | `STORAGE_BRIDGE` | Barramento de dados dedicado NFS/SMB | Bridge Linux sem gateway, sem DHCP e sem DNS. Acesso direto ponto-a-ponto entre nós consumidores e a VM de armazenamento. |

---

## 3. Acesso Remoto e VPNs (WireGuard & Gluetun)

- **WireGuard Centralizado no OPNsense**: Fornece túnel seguro para endpoints autorizados fora da residência com resolução garantida via cliente DDNS integrado no firewall.
- **Split Tunneling Rigoroso**: Dispositivos móveis e clientes remotos roteiam apenas tráfego com destino às subredes internas (`192.168.x.0/24`), evitando sobrecarga de tráfego geral da internet pelo link residencial.
- **Isolamento de Contêineres de Download (Gluetun)**: Contêineres dedicados a ingestão de dados trafegam exclusivamente através de um contêiner de VPN sidecar (`gluetun`), com kill-switch a nível de rede para impedir vazamento de IP real (*IP leaks*).
