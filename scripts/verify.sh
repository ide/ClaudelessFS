#!/bin/zsh
# End-to-end verification of ClaudelessFS staleness handling and passthrough
# integrity against the INSTALLED extension. Run from outside any mount; uses
# /tmp/clfs-test2 as scratch. Exits nonzero on any failure.
set -u
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1" }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1" }
check(){ [ "$1" = "$2" ] && ok "$3" || bad "$3 (got '$1', want '$2')" }

ROOT=/tmp/clfs-test2/src
cd /tmp
claudelessfs unmount $ROOT >/dev/null 2>&1
rm -rf /tmp/clfs-test2
# Build the tree BEFORE mounting so no item holds a createItem fd.
mkdir -p $ROOT/a/b $ROOT/flip $ROOT/dirmove
echo "agents-a"    > $ROOT/a/AGENTS.md
echo "hello"       > $ROOT/a/b/c.txt
echo "original"    > $ROOT/a/b/fresh.txt
echo "agents-flip" > $ROOT/flip/AGENTS.md
echo "agents-dm"   > $ROOT/dirmove/AGENTS.md
claudelessfs mount $ROOT >/dev/null || { echo "mount failed"; exit 1 }

echo "== T1: held-fd read survives ancestor rename =="
exec 3< $ROOT/a/b/fresh.txt
mv $ROOT/a $ROOT/z
content=$(cat <&3); exec 3<&-
check "$content" "original" "read via held fd after rename"

echo "== T2: cwd-relative access survives ancestor rename =="
( cd $ROOT/z/b
  mv $ROOT/z $ROOT/a
  c=$(cat fresh.txt 2>/dev/null); l=$(ls 2>/dev/null | head -1)
  check "$c" "original" "cat from renamed cwd"
  [ -n "$l" ] && ok "ls from renamed cwd" || bad "ls from renamed cwd"
)

echo "== T3: held fd never reads an imposter at the old path =="
exec 3< $ROOT/a/b/fresh.txt
mv $ROOT/a $ROOT/z
mkdir -p $ROOT/a/b && echo "IMPOSTER" > $ROOT/a/b/fresh.txt
content=$(cat <&3); exec 3<&-
check "$content" "original" "held fd reads original, not imposter"
rm -rf $ROOT/a && mv $ROOT/z $ROOT/a

echo "== T4: chmod through post-rename path =="
mv $ROOT/a $ROOT/z && chmod 640 $ROOT/z/b/c.txt \
  && check "$(stat -f %Lp $ROOT/z/b/c.txt)" "640" "chmod after rename" \
  || bad "chmod after rename"
mv $ROOT/z $ROOT/a

echo "== T5: .claude/CLAUDE.md created -> virtual withdraws promptly =="
cd $ROOT/flip
v=$(cat CLAUDE.md 2>/dev/null)
check "$v" "agents-flip" "virtual link active before flip"
mkdir .claude && echo "real-config" > .claude/CLAUDE.md
t0=$(python3 -c 'import time; print(time.time())')
n=0
while cat CLAUDE.md >/dev/null 2>&1; do
  n=$((n+1)); [ $n -gt 200 ] && break; sleep 0.05
done
t1=$(python3 -c 'import time; print(time.time())')
if [ $n -le 200 ] && ! cat CLAUDE.md >/dev/null 2>&1; then
  ok "virtual withdrew in $(python3 -c "print(f'{($t1-$t0)*1000:.0f}')") ms"
else
  bad "virtual still served after ~10s"
fi

echo "== T6: .claude/CLAUDE.md deleted -> virtual returns promptly =="
rm .claude/CLAUDE.md
t0=$(python3 -c 'import time; print(time.time())')
n=0
until cat CLAUDE.md >/dev/null 2>&1; do
  n=$((n+1)); [ $n -gt 200 ] && break; sleep 0.05
done
t1=$(python3 -c 'import time; print(time.time())')
if cat CLAUDE.md >/dev/null 2>&1; then
  ok "virtual returned in $(python3 -c "print(f'{($t1-$t0)*1000:.0f}')") ms"
else
  bad "virtual did not return after ~10s"
fi
rmdir .claude
sleep 0.5  # let queued nudges drain before probing refusal semantics

echo "== T7: rm on a valid virtual link is refused and link survives =="
err=$(rm CLAUDE.md 2>&1); rc=$?
[ $rc -ne 0 ] && ok "rm refused (rc=$rc)" || bad "rm was not refused: $err"
check "$(cat CLAUDE.md 2>/dev/null)" "agents-flip" "link survives refused rm"

echo "== T8: renaming a whole .claude dir flips synthesis =="
mkdir .claude && echo x > .claude/CLAUDE.md
sleep 0.5
cat CLAUDE.md >/dev/null 2>&1 && bad "virtual served with .claude present" || ok "virtual withdrawn with .claude present"
mv .claude claude-parked
sleep 0.5
check "$(cat CLAUDE.md 2>/dev/null)" "agents-flip" "virtual returns after .claude moved away"
mv claude-parked .claude
sleep 0.5
cat CLAUDE.md >/dev/null 2>&1 && bad "virtual served after .claude moved back" || ok "virtual withdrawn after .claude moved back"
rm .claude/CLAUDE.md && rmdir .claude
sleep 0.5

echo "== T9: real CLAUDE.md renamed into place wins; removing it restores =="
echo "real-file" > incoming.md
mv incoming.md CLAUDE.md
sleep 0.5
check "$(cat CLAUDE.md 2>/dev/null)" "real-file" "real file wins after rename-into-place"
rm CLAUDE.md
sleep 0.5
check "$(cat CLAUDE.md 2>/dev/null)" "agents-flip" "virtual returns after real file removed"

echo "== T10: no nudge artifacts, no dir listing pollution =="
ls -a $ROOT/flip | grep -q claudelessfs-nudge && bad "nudge name visible in ls" || ok "nudge name not in ls"
claudelessfs unmount $ROOT >/dev/null 2>&1
find /tmp/clfs-test2 -name '*claudelessfs-nudge*' | grep -q . && bad "nudge artifact on disk" || ok "no nudge artifact on backing store"
claudelessfs mount $ROOT >/dev/null

echo "== T11: rename of dir containing AGENTS.md keeps virtual working =="
mv $ROOT/dirmove $ROOT/dirmoved
check "$(cat $ROOT/dirmoved/CLAUDE.md 2>/dev/null)" "agents-dm" "virtual works at new dir path"
cat $ROOT/dirmove/CLAUDE.md >/dev/null 2>&1 && bad "virtual still at old dir path" || ok "old dir path gone"

echo "== T13: rm refusal survives flip cycling (stale-lnode regression) =="
cd $ROOT/flip
cat CLAUDE.md >/dev/null 2>&1
mkdir .claude && echo real > .claude/CLAUDE.md
until ! cat CLAUDE.md >/dev/null 2>&1; do sleep 0.05; done
rm .claude/CLAUDE.md
until cat CLAUDE.md >/dev/null 2>&1; do sleep 0.05; done
rmdir .claude
sleep 0.5
out=$(python3 -c '
import os
try:
    os.unlink("CLAUDE.md"); print("zero")
except OSError as e:
    import errno as E; print(E.errorcode[e.errno])
')
check "$out" "EPERM" "unlink refused with EPERM after flip cycle"
check "$(cat CLAUDE.md 2>/dev/null)" "agents-flip" "link intact after flip-cycle rm"

echo "== T14: mass file creation (fd-limit regression) =="
mkdir -p $ROOT/mass && cd $ROOT/mass
fails=0
for i in {1..1000}; do echo x > m$i.txt 2>/dev/null || fails=$((fails+1)); done
check "$fails" "0" "1000 rapid creates, no EMFILE"
n=$(ls | wc -l | tr -d " ")
check "$n" "1000" "all 1000 files exist"
cd /tmp

echo "== T12: passthrough sanity (git) =="
cd $ROOT/a && git init -q . 2>/dev/null && git add -A && git -c user.email=t@t -c user.name=t commit -qm test && ok "git init/add/commit under mount" || bad "git sanity"
cd /tmp

echo
echo "RESULT: $PASS passed, $FAIL failed"
claudelessfs unmount $ROOT >/dev/null 2>&1
exit $FAIL
