# shellcheck shell=bash
# 统一输出。所有模块 source 本文件。

if [ -t 1 ]; then
    C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
    C_B=$'\033[1;34m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
    C_R=; C_G=; C_Y=; C_B=; C_D=; C_0=
fi

log()  { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
step() { printf '%s[%s/%s]%s %s\n' "$C_B" "$1" "$2" "$C_0" "$3"; }
dim()  { printf '%s%s%s\n' "$C_D" "$*" "$C_0"; }
