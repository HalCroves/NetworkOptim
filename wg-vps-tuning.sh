#!/bin/bash
# ================================================================
#  wg-vps-tuning.sh — Optimisations VPS pour WireGuard gaming
#  À exécuter en root sur le VPS : sudo bash wg-vps-tuning.sh
#
#  Applique :
#   [1/3] BBR  (congestion control adapté aux liens mobiles)
#   [2/3] sysctl  (buffers UDP/TCP, latence, backlog)
#   [3/3] iptables DSCP EF  (priorisation du trafic WireGuard)
# ================================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit être lancé en root : sudo bash $0"
    exit 1
fi

IFACE=$(ip route | awk '/default/ { print $5 }' | head -1)
[ -z "$IFACE" ] && IFACE="eth0"
echo "Interface détectée : $IFACE"
echo ""

# ================================================================
#  [1/3] BBR — Congestion control optimisé pour liens mobiles/variables
# ================================================================
echo "=== [1/3] BBR (congestion control) ==="

modprobe tcp_bbr 2>/dev/null || true

if lsmod | grep -q tcp_bbr || grep -qr tcp_bbr /lib/modules/$(uname -r)/kernel/net/ 2>/dev/null; then
    sysctl_set() {
        local key="$1" val="$2"
        if grep -qxF "${key} = ${val}" /etc/sysctl.conf 2>/dev/null; then
            sed -i "s|^${key}.*|${key} = ${val}|" /etc/sysctl.conf
        elif grep -q "^${key}" /etc/sysctl.conf 2>/dev/null; then
            sed -i "s|^${key}.*|${key} = ${val}|" /etc/sysctl.conf
        else
            echo "${key} = ${val}" >> /etc/sysctl.conf
        fi
        echo "  ${key} = ${val}"
    }
    sysctl_set "net.core.default_qdisc"           "fq"
    sysctl_set "net.ipv4.tcp_congestion_control"  "bbr"
    echo "  OK — BBR activé"
else
    echo "  [WARN] Module tcp_bbr non disponible sur ce kernel — skipped"
    echo "  Vérifiez : uname -r  et  modprobe tcp_bbr"
fi
echo ""

# ================================================================
#  [2/3] sysctl — Buffers UDP/TCP + tuning réseau pour gaming
# ================================================================
echo "=== [2/3] sysctl réseau ==="

apply_sysctl() {
    local key="$1" val="$2"
    if grep -q "^${key}" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s|^${key}.*|${key} = ${val}|" /etc/sysctl.conf
    else
        echo "${key} = ${val}" >> /etc/sysctl.conf
    fi
    echo "  ${key} = ${val}"
}

# Buffers réseau — WireGuard est UDP, ces valeurs réduisent les drops sous charge
apply_sysctl "net.core.rmem_max"                    "67108864"
apply_sysctl "net.core.wmem_max"                    "67108864"
apply_sysctl "net.core.rmem_default"                "1048576"
apply_sysctl "net.core.wmem_default"                "1048576"
apply_sysctl "net.ipv4.udp_rmem_min"                "16384"
apply_sysctl "net.ipv4.udp_wmem_min"                "16384"
# Backlog — réduit les drops à haute fréquence de paquets
apply_sysctl "net.core.netdev_max_backlog"          "5000"
apply_sysctl "net.core.somaxconn"                   "4096"
# TCP fastopen — réduit la latence sur nouvelles connexions
apply_sysctl "net.ipv4.tcp_fastopen"                "3"
# Désactive slow-start après idle — stable le débit après une pause
apply_sysctl "net.ipv4.tcp_slow_start_after_idle"   "0"
# Réduit le notsent_lowat — latence d'écriture TCP plus faible
apply_sysctl "net.ipv4.tcp_notsent_lowat"           "16384"
# Forwarding IP (requis pour WireGuard routing)
apply_sysctl "net.ipv4.ip_forward"                  "1"

sysctl -p > /dev/null 2>&1 && echo "  sysctl -p : OK" || echo "  [WARN] sysctl -p a signalé des erreurs (voir ci-dessus)"
echo ""

# ================================================================
#  [3/3] iptables DSCP EF (46) — Priorisation trafic WireGuard
# ================================================================
echo "=== [3/3] iptables DSCP EF (46) ==="

# Vérifie si l'extension DSCP est disponible
if ! iptables -t mangle -A OUTPUT -j DSCP --set-dscp-class EF --dry-run 2>/dev/null; then
    # Certains kernels ne supportent pas --dry-run, on tente directement
    if ! iptables -t mangle -L FORWARD | grep -q DSCP 2>/dev/null; then
        echo "  Vérification module xt_dscp..."
        modprobe xt_dscp 2>/dev/null || true
    fi
fi

add_rule_once() {
    local table="$1" chain="$2"; shift 2
    if ! iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
        iptables -t "$table" -A "$chain" "$@"
        echo "  Ajouté : iptables -t $table -A $chain $*"
    else
        echo "  Déjà présent : -t $table -A $chain $*"
    fi
}

# Trafic UDP entrant depuis le client WireGuard (jeu → serveur via VPS)
add_rule_once mangle FORWARD -i wg0 -p udp -j DSCP --set-dscp-class EF

# Trafic UDP retour (serveur → client via VPS)
add_rule_once mangle FORWARD -o wg0 -p udp -j DSCP --set-dscp-class EF

# Bonus : marquer aussi les ports Valve en TCP (lobbies, matchmaking)
add_rule_once mangle FORWARD -i wg0 -p tcp --dport 27015:27036 -j DSCP --set-dscp-class EF
add_rule_once mangle FORWARD -o wg0 -p tcp --sport 27015:27036 -j DSCP --set-dscp-class EF

echo ""

# ── Persistance des règles iptables ────────────────────────────
echo "=== Persistance iptables ==="
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
    echo "  Sauvegardé via netfilter-persistent"
elif command -v iptables-save &>/dev/null; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    echo "  Sauvegardé dans /etc/iptables/rules.v4"
    # Assurer le chargement au démarrage si iptables-persistent est installé
    if [ -f /etc/network/if-pre-up.d/iptables ]; then
        echo "  Chargement automatique via if-pre-up.d déjà configuré"
    else
        echo "  Pour charger au boot : apt install iptables-persistent"
    fi
else
    echo "  [WARN] Aucun outil de persistance trouvé — règles perdues au reboot"
    echo "  Installer : apt install iptables-persistent"
fi

echo ""
echo "================================================================"
echo " RÉSUMÉ"
echo "================================================================"
echo " BBR  : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A')"
echo " fq   : $(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'N/A')"
echo " fwd  : $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 'N/A')"
echo " DSCP : $(iptables -t mangle -L FORWARD --line-numbers -n 2>/dev/null | grep -c DSCP || echo 0) règles DSCP actives"
echo "================================================================"
echo " Redémarrage recommandé pour valider tous les changements."
echo "================================================================"
