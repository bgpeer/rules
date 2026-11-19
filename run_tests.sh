#!/usr/bin/env bash
# 跑 tests/ 下的全部回归测试 (纯标准库 unittest, 不用 pytest), 列出没过的;
# 全过退出码 0, 有失败退出码 1。
# 用法: bash run_tests.sh            全部
#       bash run_tests.sh parse      只跑文件名里带 parse 的
cd "$(dirname "$0")" || exit 1

# 先过语法关: helpers.py 语法坏了, 后面所有测试都没意义
python3 -m py_compile scripts/helpers.py || { echo "✖ scripts/helpers.py 语法错误"; exit 1; }

pat="${1:-}"
pass=0
fail=0
failed=()
for f in tests/test_*${pat}*.py; do
  [ -e "$f" ] || continue
  if out=$(timeout 300 python3 "$f" </dev/null 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^ok$' || true)
    echo "✔ $f"
    pass=$((pass + 1))
  else
    echo "✖ $f"
    printf '%s\n' "$out" | grep -e '^FAIL' -e '^ERROR' -e 'Error' | head -10 | sed 's/^/    /'
    fail=$((fail + 1))
    failed+=("$f")
  fi
done

echo "----------------------------------------"
if [ "$fail" -eq 0 ]; then
  echo "ALL PASS（$pass 个测试文件）"
  exit 0
else
  echo "FAIL: $fail 个测试文件没过: ${failed[*]}"
  exit 1
fi
