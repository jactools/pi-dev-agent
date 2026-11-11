#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$REPO_ROOT/.test-pi-dev-apt-cache.$$"
mkdir -p "$FIXTURES/bin" "$FIXTURES/runs"
trap 'rm -rf "$FIXTURES"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Extract shell bodies separately from all leading BuildKit mount directives.
for image in base agent; do
  awk -v out="$FIXTURES/runs" -v image="$image" '
    function save(    body, mounts, name) {
      body = run
      sub(/^RUN[[:space:]]+/, "", body)
      mounts = ""
      while (match(body, /^--mount=[^[:space:]]+[[:space:]]+/)) {
        mounts = mounts substr(body, 1, RLENGTH) "\n"
        body = substr(body, RLENGTH + 1)
      }
      name = out "/" image "-" stage "-" ++count
      print mounts > (name ".mounts")
      print body > (name ".sh")
      run = ""
    }
    /^FROM / { stage = $NF; if (image == "agent") stage = "agent" }
    /^RUN / { run = $0 }
    run != "" {
      if ($0 !~ /^RUN /) run = run " " $0
      if (sub(/\\$/, "", run)) next
      save()
    }
  ' "$REPO_ROOT/docker/pi-dev-$image/Dockerfile.pi-dev-$image"
done

cat > "$FIXTURES/expected.conf" <<'EOF'
APT::Keep-Downloaded-Packages "true";
Binary::apt::APT::Keep-Downloaded-Packages "true";
Acquire::Retries "3";
Acquire::http::Timeout "60";
Acquire::https::Timeout "60";
APT::Update::Error-Mode "any";
EOF

# These doubles never invoke host APT, npm, or system configuration commands.
cat > "$FIXTURES/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${0##*/}" "$*" >> "$APT_TEST_LOG"
case "${0##*/}" in
  apt-get)
    if [[ " $* " == *" update "* && "$APT_TEST_FAIL" == update ]]; then exit 41; fi
    if [[ " $* " == *" install "* && "$APT_TEST_FAIL" == install ]]; then exit 42; fi
    ;;
  npx)
    [[ "$*" == "playwright install --with-deps chromium" ]]
    apt-get update && apt-get install -y playwright-fixture
    ;;
esac
EOF
for command in npm npx ln chmod; do
  cp "$FIXTURES/bin/apt-get" "$FIXTURES/bin/$command"
done
chmod +x "$FIXTURES/bin/"*
export PATH="$FIXTURES/bin:$PATH"
export APT_TEST_LOG="$FIXTURES/commands.log" APT_TEST_FAIL=none
export MOODY_PYTHON_VERSION=3.13 PI_CODING_AGENT_VERSION=test-agent PLAYWRIGHT_VERSION=test-playwright

apt_runs=0
configs=0
for body in "$FIXTURES/runs/"*.sh; do
  sh -n "$body"
  mounts="${body%.sh}.mounts"
  if grep -Eq '/var/lib/dpkg|type=cache.*(npmrc|/run/secrets|/root/\.npm)' "$mounts"; then
    fail "installed state and npm secrets must not be cached: $mounts"
  fi
  if grep -Eq '(apt(-get)?[[:space:]]+clean|rm[[:space:]].*/var/(cache/apt|lib/apt/lists))' "$body"; then
    fail "APT caches must not be cleaned: $body"
  fi

  if grep -Fq '/etc/apt/apt.conf.d/docker-clean' "$body"; then
    case "$body" in
      */base-base-*|*/base-java_source-*) ;;
      *) fail "unexpected APT configuration stage" ;;
    esac
    configs=$((configs + 1))
    conf_dir="$FIXTURES/config-$configs"
    mkdir "$conf_dir"
    printf 'DPkg::Post-Invoke {"delete archives";};\n' > "$conf_dir/docker-clean"
    sed "s|/etc/apt/apt.conf.d|$conf_dir|g" "$body" > "$FIXTURES/config.sh"
    sh "$FIXTURES/config.sh"
    [[ ! -e "$conf_dir/docker-clean" ]] || fail "docker-clean hook remains"
    cmp -s "$FIXTURES/expected.conf" "$conf_dir/99pi-dev-cache" ||
      fail "keep-download/retry/timeout/strict-update configuration differs"
  fi

  if ! grep -Eq 'apt(-get)?[[:space:]]|playwright install --with-deps' "$body"; then
    continue
  fi
  apt_runs=$((apt_runs + 1))
  family=moody
  [[ "$body" != *base-java_source-* ]] || family=temurin
  for cache in archives lists; do
    target=/var/cache/apt
    [[ "$cache" != lists ]] || target=/var/lib/apt/lists
    expected="--mount=type=cache,id=pi-dev-$family-apt-$cache-\${TARGETARCH},target=$target,sharing=locked"
    [[ "$(grep -Fc -- "$expected" "$mounts")" -eq 1 ]] ||
      fail "missing compatible locked $cache cache: $body"
  done
  [[ "$(grep -c -- '--mount=type=cache' "$mounts")" -eq 2 ]] ||
    fail "unexpected cache mount: $body"
  if grep -Eq 'apt-get .*update' "$body"; then
    grep -Eq 'apt-get .*APT::Update::Error-Mode=any update' "$body" ||
      fail "APT update must fail for any metadata error"
  fi
  if grep -Fq 'playwright install --with-deps' "$body"; then
    grep -Eq -- '^--mount=type=secret,id=npmrc[[:space:]]*$' "$mounts" ||
      fail "optional npmrc secret must remain on the Playwright RUN"
  fi

  # Redirect only fixture paths; never read the real npm secret or touch /tmp.
  sed "s|/run/secrets/npmrc|$FIXTURES/absent-npmrc|g; s|cd /tmp|cd \"$FIXTURES\"|g" \
    "$body" > "$FIXTURES/apt.sh"
  for mode in none update install; do
    export APT_TEST_FAIL="$mode"
    : > "$APT_TEST_LOG"
    status=0
    sh "$FIXTURES/apt.sh" || status=$?
    case "$mode" in
      none) [[ "$status" -eq 0 ]] || fail "APT RUN failed with successful doubles" ;;
      update|install)
        expected_status=41
        [[ "$mode" != install ]] || expected_status=42
        [[ "$status" -eq "$expected_status" ]] || fail "$mode failure masked: $body"
        [[ "$(tail -n 1 "$APT_TEST_LOG")" == apt-get\|* ]] ||
          fail "commands continued after APT failure"
        if [[ "$mode" == update ]] && grep -q '^apt-get|.*install' "$APT_TEST_LOG"; then
          fail "install continued after failed update"
        fi
        ;;
    esac
  done
done
[[ "$apt_runs" -eq 8 ]] || fail "expected six base and two agent APT-using RUNs"
[[ "$configs" -eq 2 ]] || fail "both independent base stages need APT configuration"

# Architecture arguments must be in each independent scope; derived stages inherit.
awk '
  /^FROM / { stage = $NF }
  /^ARG TARGETARCH$/ { arch[stage]++ }
  END { exit !(arch["base"] == 1 && arch["java_source"] == 1) }
' "$REPO_ROOT/docker/pi-dev-base/Dockerfile.pi-dev-base" ||
  fail "base and Java source must declare TARGETARCH"
grep -Fxq 'ARG TARGETARCH' "$REPO_ROOT/docker/pi-dev-agent/Dockerfile.pi-dev-agent" ||
  fail "agent must declare TARGETARCH"

bash -n "$SCRIPT_DIR/test_pi_dev_apt_cache.sh"
echo "PASS: all eight APT/Playwright RUNs use compatible locked archive/index caches."
echo "PASS: both independent configurations executed; update/install failures propagate."
echo "All APT cache checks passed (command doubles only; no Docker, host APT, or network)."
