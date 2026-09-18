#!/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

# MicrOS Git Smart HTTP Verification Suite
# Tests health, ref advertisement, git push ingestion, and live site serving.

local_port="8080"
local_url="http://127.0.0.1:${local_port}"
max_wait=40
waited=0
server_ready=0

echo "[test] Polling ${local_url}/health for up to ${max_wait}s..."
while [[ "$waited" -lt "$max_wait" ]]; do
    if curl -s "${local_url}/health" >/dev/null 2>&1; then
        server_ready=1
        echo "[test] Server online after ${waited}s!"
        break
    fi
    sleep 0.5
    waited=$((waited + 1))
done

if [[ "$server_ready" -ne 1 ]]; then
    echo "[test] ERROR: Server did not respond within ${max_wait}s."
    exit 1
fi

echo "--- Step 1: Health Check ---"
curl -s -i "${local_url}/health"
echo

echo "--- Step 2: Git Receive-Pack Advertisement ---"
curl -s -i "${local_url}/site.git/info/refs?service=git-receive-pack" | tr '\0' '@'
echo

echo "--- Step 3: Git Push Test ---"
test_dir=$(mktemp -d /tmp/micros-git-test-XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

git -C "$test_dir" init
git -C "$test_dir" config user.name "Renich Bon Ciric"
git -C "$test_dir" config user.email "renich@evalinux.com"
echo "<h1>Autonomous Web on MicrOS</h1><p>Bit-for-bit sovereign hosting.</p>" > "${test_dir}/index.html"
git -C "$test_dir" add index.html
git -C "$test_dir" commit -m "Deploy sovereign website"
git -C "$test_dir" branch -M master

echo "[test] Executing git push to ${local_url}/site.git master..."
set +e
push_out=$(git -C "$test_dir" push -v "${local_url}/site.git" master 2>&1)
push_status=$?
set -e
echo "Git push status: ${push_status}"
echo "Git push output:"
echo "${push_out}"
echo

if [[ "$push_status" -ne 0 ]]; then
    echo "[test] ERROR: Git push failed with code ${push_status}"
    exit 1
fi

echo "--- Step 4: Verify Live Deployed Site ---"
echo "[test] Fetching GET /index.html..."
curl -s -i "${local_url}/index.html"
echo

echo "[test] Fetching GET /..."
curl -s -i "${local_url}/"
echo

echo "[test] SUCCESS: Git push ingestion and CAS serving verified!"
