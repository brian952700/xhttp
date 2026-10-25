#!/usr/bin/env bash
# CI ONLY: deterministic certificate installation adapter; never contacts a CA.
set -euo pipefail
mode= key= cert= reload= domain= home=
while (($#)); do
    case $1 in
        --upgrade|--install-cert|--remove|--issue|--renew) mode=$1; shift;;
        --key-file) key=$2; shift 2;;
        --fullchain-file) cert=$2; shift 2;;
        --reloadcmd) reload=$2; shift 2;;
        --home) home=$2; shift 2;;
        -d) domain=$2; shift 2;;
        --server|--keylength) shift 2;;
        --auto-upgrade|--ecc|--standalone|--force) shift;;
        *) printf 'Unexpected fixture argument: %s\n' "$1" >&2; exit 1;;
    esac
done
case $mode in
    --upgrade) exit 0;;
    --remove) mv -- "$home/${domain}_ecc/$domain.conf" "$home/${domain}_ecc/$domain.conf.removed";;
    --issue) printf 'CI: public issuance intentionally unavailable\n' >&2; exit 1;;
    --renew)
        [[ -s "$home/${domain}_ecc/fullchain.cer" ]]
        # Real acme.sh copies renewed files and invokes its saved reload command.
        install -m 0600 "$home/${domain}_ecc/key.pem" "/etc/xray-cert/staging/$domain/server.key"
        install -m 0600 "$home/${domain}_ecc/fullchain.cer" "/etc/xray-cert/staging/$domain/server.crt";;
    --install-cert)
        install -m 0600 "$home/${domain}_ecc/key.pem" "$key"
        install -m 0600 "$home/${domain}_ecc/fullchain.cer" "$cert"
        bash -c "$reload";;
    *) exit 1;;
esac
