#!/bin/bash
set -e
export LC_ALL=C
shopt -s nullglob

# Обработка ошибок
handle_error() {
	echo "$(lsb_release -ds) $(uname -r) $(date --iso-8601=seconds)"
	echo -e "\e[1;31mError at line $1: $2\e[0m"
	exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

if [[ -z "$1" ]]; then
	echo 'Check how a host is routed for AntiZapret VPN clients'
	echo
	echo 'Usage: /root/antizapret/check-host.sh <host|url> [host|url]...'
	echo 'Example: /root/antizapret/check-host.sh https://www.cybenetics.com/ example.com'
	exit 1
fi

cd /root/antizapret
source setup

[[ "$ALTERNATIVE_CLIENT_IP" == 'y' ]] && IP="${CLIENT_IP:-172}" || IP=10
[[ "$ALTERNATIVE_FAKE_IP" == 'y' ]] && FAKE_IP="${FAKE_IP:-198.18}" || FAKE_IP="$IP.30"
FAKE_RANGE="$FAKE_IP.0.0/15"

if [[ ! -f result/include-hosts.txt || ! -f result/exclude-hosts.txt ]]; then
	echo -e "\e[1;31mLists are missing! Run /root/antizapret/doall.sh first\e[0m"
	exit 2
fi

# Приводим адрес к доменному имени: убираем схему, логин, порт, путь и точку в конце
normalize_host() {
	local host="${1,,}"
	host="${host#*://}"
	host="${host##*@}"
	host="${host%%/*}"
	host="${host%%\?*}"
	host="${host%%#*}"
	host="${host%%:*}"
	host="${host#.}"
	host="${host%.}"
	echo "$host"
}

# Ищем совпадение в списке доменов так же, как это делает Knot Resolver в proxy.rpz:
# сначала проверяется само имя, затем родительские домены (записи '*.домен'),
# выигрывает самое специфичное совпадение - выводим его номер, меньше значит специфичнее
match_index() {
	printf '%s\n' "${SUFFIXES[@]}" | awk '
		NR==FNR { if (!($0 in idx)) idx[$0] = FNR; next }
		($0 in idx) { if (!found || idx[$0] < found) found = idx[$0] }
		END { if (found) print found }
	' - "$1"
}

# Запрашиваем A-записи у резолвера, dnslib уже установлен для proxy.py
# Код python не отступаем - heredoc должен сохранить отступы самого python
resolve_a() {
python3 - "$1" "$2" 2>/dev/null <<'EOF' || true
import sys
from dnslib import DNSRecord, QTYPE
try:
    reply = DNSRecord.parse(DNSRecord.question(sys.argv[2], 'A').send(sys.argv[1], 53, timeout=5))
    for rr in reply.rr:
        if rr.rtype == QTYPE.A:
            print(rr.rdata)
except Exception:
    pass
EOF
}

# Проверяем принадлежность IPv4-адреса подсетям из файла или из аргумента
ip_in_nets() {
python3 - "$@" 2>/dev/null <<'EOF' || true
import sys, ipaddress
try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit(0)
nets = []
for arg in sys.argv[2:]:
    try:
        nets.extend(open(arg).read().split())
    except OSError:
        nets.append(arg)
for net in nets:
    try:
        if ip in ipaddress.ip_network(net, strict=False):
            print(net)
            break
    except ValueError:
        continue
EOF
}

# Показываем какие списки IP-адресов провайдеров сейчас отключены в setup
disabled_ip_lists() {
	local name value
	for name in DISCORD CLOUDFLARE AMAZON HETZNER DIGITALOCEAN OVH TELEGRAM GOOGLE AKAMAI WHATSAPP ROBLOX; do
		value="${name}_INCLUDE"
		[[ "${!value}" != 'y' ]] && echo -n " ${name}_INCLUDE"
	done
}

echo 'Check AntiZapret VPN routing:'
echo "Fake IP range: $FAKE_RANGE"
echo

for arg in "$@"; do
	HOST="$(normalize_host "$arg")"

	if [[ -z "$HOST" || "$HOST" != *.* ]]; then
		echo -e "\e[1;31m$arg - not a valid host\e[0m"
		echo
		continue
	fi

	echo -e "\e[1;32m$HOST\e[0m"

	# Формируем список имен от самого специфичного к самому общему
	SUFFIXES=()
	name="$HOST"
	while [[ -n "$name" ]]; do
		SUFFIXES+=("$name")
		[[ "$name" != *.* ]] && break
		name="${name#*.}"
	done
	SUFFIXES+=('.')

	INCLUDE="$(match_index result/include-hosts.txt)"
	EXCLUDE="$(match_index result/exclude-hosts.txt)"

	# При равной специфичности выигрывает исключение - оно записано в proxy.rpz последним
	if [[ -n "$INCLUDE" && ( -z "$EXCLUDE" || "$INCLUDE" -lt "$EXCLUDE" ) ]]; then
		LISTED='y'
		echo "  Domain list:  included by '${SUFFIXES[$((INCLUDE - 1))]}'"
	else
		LISTED='n'
		if [[ -n "$EXCLUDE" ]]; then
			echo "  Domain list:  excluded by '${SUFFIXES[$((EXCLUDE - 1))]}'"
		else
			echo '  Domain list:  not listed'
		fi
	fi

	# Что отдает клиенту DNS АнтиЗапрета и какие адреса у домена на самом деле
	ANTIZAPRET_IPS="$(resolve_a 127.1.1.1 "$HOST")"
	REAL_IPS="$(resolve_a 127.2.2.2 "$HOST")"
	echo "  AntiZapret DNS: ${ANTIZAPRET_IPS:-no answer}" | tr '\n' ' '; echo
	echo "  Real IPs:       ${REAL_IPS:-no answer}" | tr '\n' ' '; echo

	# Подменный IP означает, что трафик уйдет в туннель и на сервере будет развернут в реальный
	FAKE='n'
	for ip in $ANTIZAPRET_IPS; do
		if [[ -n "$(ip_in_nets "$ip" "$FAKE_RANGE")" ]]; then
			FAKE='y'
			REAL="$(iptables -w -t nat -S ANTIZAPRET-MAPPING 2>/dev/null | awk -v ip="$ip/32" '$4 == ip {print $NF; exit}')"
			echo "  Mapping:      $ip -> ${REAL:-not mapped yet}"
		fi
	done

	# Реальный IP-адрес может попадать в маршруты, которые клиент получает от сервера
	ROUTED=''
	if [[ -f result/route-ips.txt ]]; then
		for ip in $REAL_IPS; do
			NET="$(ip_in_nets "$ip" result/route-ips.txt)"
			[[ -n "$NET" ]] && ROUTED="$ip in $NET" && break
		done
	fi
	[[ -n "$ROUTED" ]] && echo "  Route by IP:  $ROUTED"

	if [[ "$FAKE" == 'y' ]]; then
		echo -e "  Result:       \e[1;32mAntiZapret VPN\e[0m (by domain)"
	elif [[ -n "$ROUTED" ]]; then
		echo -e "  Result:       \e[1;32mAntiZapret VPN\e[0m (by IP)"
	elif [[ -z "$ANTIZAPRET_IPS" && "$LISTED" == 'y' ]]; then
		echo -e "  Result:       \e[1;33mUnknown\e[0m - the domain is listed, but AntiZapret DNS did not answer"
		echo '                Check kresd@1 and run /root/antizapret/doall.sh'
	else
		echo -e "  Result:       \e[1;31mDirect via client ISP\e[0m"
		echo '                This host is not routed through AntiZapret VPN, so it stays'
		echo "                subject to the client's ISP - that is what makes a page fail"
		echo '                or load only partially'
		if [[ "$LISTED" == 'y' ]]; then
			echo '                The domain is listed, but AntiZapret DNS returned a real IP -'
			echo '                check kresd@1 and run /root/antizapret/doall.sh'
		else
			echo '                Add the domain to config/include-hosts.txt'
			for ip in $REAL_IPS; do
				echo "                or the IP $ip to config/include-ips.txt"
				break
			done
			LISTS="$(disabled_ip_lists)"
			[[ -n "$LISTS" ]] && echo "                Hosting IP lists turned off in setup:$LISTS"
		fi
	fi
	echo
done

exit 0
