#!/bin/sh
# Delin 用户管理自检 (passwd / useradd / userdel / usermod / groupadd / groupdel / id / whoami /
# groups)。可移植 POSIX sh; 两处各跑一次并要求输出一致:
#   宿主: lua5.1 tools/harness.lua /bin/sh < scripts/user_test.sh
#   真机: 由 realmachine_verify.sh 调用(sh /root/user_test.sh >> $LOG)
# 输出 "ok <name>" / "ng <name>", 全 ok 退出码 0。
#
# 约定(与 proc_test/redstone_test 一致):
#   - 不打印任何每次运行都不同的值(时间/pid/inode); 断言的是稳定量;
#   - 断言"密码是否可用"一律问内核(user_helper.lua verify, 与 login 判定同源), 不直接读
#     /etc/shadow —— 真机上它是 0600 root:root, 而宿主测试台的宿主文件权限不模拟这一条;
#   - 断言消息用 grep -x -F(整行、字面): Delin 的 grep 用 Lua pattern, 正则里的 ()/./- 都有
#     别的含义, 拿它比对含这些字符的文本会误判;
#   - 需要普通用户身份的分支(改自己密码要旧密码、非 root 被拒)由 user_helper.lua 用内核
#     spawn(uid) 起进程 —— Delin 没有 su/setuid, 这是唯一能拿到非 root 进程的办法;
#   - 工具的错误提示与提示符都写 stderr, 而 Delin 的 stderr 就是 stdout, 所以断言消息用
#     chkcontain(子串)而不是 chkeq(整行)。
#   - 自检会真的改 /etc/{passwd,shadow,group}(真机上只影响这次验证用的镜像)。
#
# 注意: 本脚本依赖的初始状态是"与 src/etc 相同的用户表"(root 0, alice 1000, 无其它用户) ——
# 部署镜像与宿主测试台都是这个状态; 不依赖任何**原有密码**(两边盐不同), 密码一律在脚本里现设。

T=/tmp/usertest
H=/root/user_helper.lua
outcome=0
rm -rf $T
mkdir -p $T

ok() { echo "ok $1"; }
ng() { echo "ng $1"; outcome=1; }
chk() { # chk <name> <cmd...>: 退出码 0 即通过, 输出留在 $T/last
    _n="$1"; shift
    "$@" > $T/last
    if [ "$?" = "0" ]; then ok "$_n"; else ng "$_n"; fi
}
chkneg() { # 退出码非 0 即通过(输出留在 $T/last)
    _n="$1"; shift
    "$@" > $T/last
    if [ "$?" != "0" ]; then ok "$_n"; else ng "$_n"; fi
}
chkeq() { # chkeq <name> <expected-line> <file>
    if [ "$2" = "" ]; then
        if [ -s "$3" ]; then ng "$1"; else ok "$1"; fi
    else
        grep -x -F -- "$2" "$3" > $T/hit
        if [ -s $T/hit ]; then ok "$1"; else ng "$1"; fi
    fi
}
chkcontain() { # chkcontain <name> <pattern> <file>
    grep "$2" "$3" > $T/hit
    if [ -s $T/hit ]; then ok "$1"; else ng "$1"; fi
}
chkempty() { # 文件必须为空
    if [ -s "$2" ]; then ng "$1"; else ok "$1"; fi
}
# 以 <uid> 跑 /bin/<tool>, 退出码即本函数的退出码: asuser <uid> <tool> <in|-> <out> [args...]
# 等子进程这件事由这里(sh)做: user_helper.lua 只负责 spawn 并打印 pid —— 它是 /bin/lua 用
# xpcall 跑的, 在 Lua 5.1 的宿主测试台上跨 pcall 让出会报错, 只有普通工具能安全地 proc.wait。
asuser() {
    _u="$1"; _t="$2"; _i="$3"; _o="$4"; shift 4
    lua $H spawn $_u $_t $_o $_i "$@" > $T/apid
    read _p < $T/apid
    if [ -z "$_p" ]; then return 127; fi
    wait $_p
}

# ---------------------------------------------------------------
# 1. 只读查询: id / whoami / groups
# ---------------------------------------------------------------
chk id_un_root id -un
chkeq id_un_root_out root $T/last
chk id_u_root id -u
chkeq id_u_root_out 0 $T/last
chk whoami_root whoami
chkeq whoami_root_out root $T/last
chk id_alice id alice
chkeq id_alice_out 'uid=1000(alice) gid=1000(alice) groups=1000(alice)' $T/last
chk id_Gn_alice id -Gn alice
chkeq id_Gn_alice_out alice $T/last
chk id_G_alice id -G alice
chkeq id_G_alice_out 1000 $T/last
chk groups_alice groups alice
chkeq groups_alice_out alice $T/last
chk groups_self groups
chkeq groups_self_out root $T/last
chkneg id_nouser id nosuchuser
chkneg id_bad_option id -q
chkneg id_two_choices id -ug
chkneg id_names_only id -n
chkneg whoami_extra_operand whoami x
chkneg groups_extra_operand groups alice root

# ---------------------------------------------------------------
# 2. root 改 alice 的密码(不问旧密码), 用内核 user.verify 判定
# ---------------------------------------------------------------
echo s3cret > $T/pw
echo s3cret >> $T/pw
chk passwd_root_sets_alice passwd alice < $T/pw
chkcontain passwd_root_sets_alice_msg 'password updated successfully' $T/last
chk verify_alice_new_pw lua $H verify alice s3cret
chkeq verify_alice_new_pw_out yes $T/last
chkneg verify_alice_wrong_pw lua $H verify alice wrongpw
chkeq verify_alice_wrong_pw_out no $T/last
chk passwd_S_alice passwd -S alice
chkeq passwd_S_alice_out 'alice P' $T/last
# 新密码两遍不一致 -> 拒绝, 且旧密码仍然有效
echo aaa > $T/pw2
echo bbb >> $T/pw2
chkneg passwd_mismatch passwd alice < $T/pw2
chk verify_alice_kept lua $H verify alice s3cret
chkeq verify_alice_kept_out yes $T/last
# 空密码 -> 拒绝(要删密码得用 -d)
echo "" > $T/pw3
echo "" >> $T/pw3
chkneg passwd_empty passwd alice < $T/pw3
chkneg passwd_bad_option passwd -x alice
chkneg passwd_two_names passwd alice root

# ---------------------------------------------------------------
# 3. useradd
# ---------------------------------------------------------------
chk useradd_bob useradd -m -c "Bob B" -G alice bob
chkeq passwd_bob_line 'bob:x:1001:1001:Bob B:/home/bob:/bin/sh' /etc/passwd
chkeq group_alice_member 'alice:x:1000:alice,bob' /etc/group
chk home_bob_created [ -d /home/bob ]
chkneg verify_bob_locked lua $H verify bob ""
chkeq verify_bob_locked_out no $T/last
chk passwd_S_bob passwd -S bob
chkeq passwd_S_bob_out 'bob L' $T/last
chk passwd_sets_bob passwd bob < $T/pw
chk verify_bob_pw lua $H verify bob s3cret
chkeq verify_bob_pw_out yes $T/last
chkneg useradd_dup useradd bob
chkneg useradd_uid_in_use useradd -u 1000 carl
chkneg useradd_bad_group useradd -g nosuchgroup dave
chkneg useradd_bad_group_list useradd -G nosuchgroup dave
chkneg useradd_bad_name useradd 'bad:name'
chkneg useradd_bad_option useradd -Z dave
chkneg useradd_no_name useradd
grep dave /etc/passwd > $T/hit
chkempty useradd_failure_wrote_nothing $T/hit

# ---------------------------------------------------------------
# 4. usermod(-G 全量 / -a 追加 / -l 改名 / -L -U / -c -s)
# ---------------------------------------------------------------
chk groupadd_staff groupadd staff
chk usermod_append_staff usermod -aG staff bob
chk groups_bob groups bob
chkeq groups_bob_out 'bob alice staff' $T/last
chk usermod_replace_groups usermod -G staff bob
chk groups_bob_replaced groups bob
chkeq groups_bob_replaced_out 'bob staff' $T/last
chk usermod_comment_shell usermod -c "Robert B" -s /bin/sh bob
chkcontain passwd_robert_comment '^bob:x:1001:1001:Robert B:' /etc/passwd
chk usermod_rename usermod -l robert bob
chk id_robert id robert
chkeq id_robert_out 'uid=1001(robert) gid=1001(bob) groups=1001(bob),1002(staff)' $T/last
chkneg id_bob_gone id bob
chk usermod_lock usermod -L robert
chk passwd_S_robert_locked passwd -S robert
chkeq passwd_S_robert_locked_out 'robert L' $T/last
chkneg verify_robert_locked lua $H verify robert s3cret
chkeq verify_robert_locked_out no $T/last
chk usermod_unlock usermod -U robert
chk passwd_S_robert_unlocked passwd -S robert
chkeq passwd_S_robert_unlocked_out 'robert P' $T/last
chk usermod_no_changes usermod robert
chkeq usermod_no_changes_out 'usermod: no changes' $T/last
chkneg usermod_nouser usermod -L nosuchuser
chkneg usermod_bad_option usermod -q robert
chkneg usermod_lock_and_unlock usermod -L -U robert
chkneg usermod_append_without_G usermod -a robert
chkneg usermod_bad_group usermod -g nosuchgroup robert
chkneg usermod_uid_in_use usermod -u 1000 robert
chkneg usermod_no_name usermod -L

# ---------------------------------------------------------------
# 5. groupadd / groupdel
# ---------------------------------------------------------------
chkneg groupadd_dup groupadd staff
chkneg groupadd_gid_in_use groupadd -g 1000 dup
chkneg groupadd_bad_gid groupadd -g x dup
chkneg groupadd_bad_name groupadd 'bad:name'
chkneg groupadd_no_name groupadd
chkneg groupdel_primary_group groupdel bob
chk groupdel_staff groupdel staff
chkneg groupdel_dup groupdel staff

# ---------------------------------------------------------------
# 6. userdel(-r 连家目录)
# ---------------------------------------------------------------
chk useradd_erin useradd -m erin
chk home_erin_created [ -d /home/erin ]
chk userdel_robert userdel robert
chkneg id_robert_gone id robert
grep robert /etc/passwd > $T/hit
chkempty passwd_robert_gone $T/hit
grep robert /etc/group > $T/hit
chkempty group_robert_gone $T/hit
chk home_robert_kept_without_r [ -d /home/bob ]
chk userdel_r_erin userdel -r erin
chkneg home_erin_removed [ -d /home/erin ]
grep erin /etc/group > $T/hit
chkempty group_erin_gone $T/hit
chkneg userdel_nouser userdel nosuchuser
chkneg userdel_no_name userdel

# ---------------------------------------------------------------
# 7. 普通用户(alice, uid 1000)视角: 内核按调用者 uid 授权
# ---------------------------------------------------------------
echo s3cret > $T/pwf
echo alice2 >> $T/pwf
echo alice2 >> $T/pwf
chk alice_changes_own_pw asuser 1000 passwd $T/pwf $T/alice_out alice
chk verify_alice_self_changed lua $H verify alice alice2
chkeq verify_alice_self_changed_out yes $T/last
chkneg verify_alice_old_pw_gone lua $H verify alice s3cret
chkeq verify_alice_old_pw_gone_out no $T/last
echo wrongpw > $T/pwf2
echo nope >> $T/pwf2
echo nope >> $T/pwf2
chkneg alice_wrong_old_pw asuser 1000 passwd $T/pwf2 $T/alice_out alice
chk verify_alice_unchanged lua $H verify alice alice2
chkeq verify_alice_unchanged_out yes $T/last
chkneg alice_passwd_root asuser 1000 passwd $T/pwf $T/alice_out root
chkneg alice_passwd_lock asuser 1000 passwd - $T/alice_out -l alice
chkneg alice_passwd_delete asuser 1000 passwd - $T/alice_out -d alice
chkneg alice_useradd asuser 1000 useradd - $T/alice_out frank
chkneg alice_usermod asuser 1000 usermod - $T/alice_out -L root
chkneg alice_userdel asuser 1000 userdel - $T/alice_out root
chkneg alice_groupadd asuser 1000 groupadd - $T/alice_out staff2
chkneg alice_groupdel asuser 1000 groupdel - $T/alice_out alice
chk alice_id_self asuser 1000 id - $T/alice_out alice
chkeq alice_sees_self 'uid=1000(alice) gid=1000(alice) groups=1000(alice)' $T/alice_out
chk alice_whoami asuser 1000 whoami - $T/alice_out
chkeq alice_whoami_out alice $T/alice_out

rm -rf $T
if [ "$outcome" = "0" ]; then echo "=== user test: all ok ==="; else echo "=== user test: FAILED ==="; fi
exit $outcome
