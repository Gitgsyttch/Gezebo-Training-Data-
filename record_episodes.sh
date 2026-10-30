#!/bin/bash
# =============================================================
# record_episodes.sh
#   CRANE+ V2 (Ignition Gazebo Fortress) の自動操作を
#   rosbag でエピソードとして連続記録するスクリプト
#
# 使い方:
#   ./record_episodes.sh [エピソード数]      例) ./record_episodes.sh 10
#
# 前提:
#   - Gazebo + コントローラを起動済み
#   - 同じフォルダに auto_teleop.exp(expect の自動操作スクリプト)がある
#   - 起動時、キューブは初期位置に置かれていること
# =============================================================

N_EPISODES=${1:-10}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
EXPECT_SCRIPT1="$SCRIPT_DIR/auto_catch.exp"
EXPECT_SCRIPT2="$SCRIPT_DIR/auto_teleop.exp"

# 保存先(実行ごとに日時のフォルダを作る → 上書き事故を防ぐ)
OUT_DIR=~/dataset/rosbags/pekori

# 記録するトピック(カメラ等があればここに追加)
TOPICS="/joint_states /tf /tf_static /clock"

# Gazebo の設定
WORLD=default
OBJ=wood_cube_5cm

# キューブの初期位置(自動取得に失敗したときに使う値)
CUBE_X=0.2
CUBE_Y=0.0
CUBE_Z=0.8

# アーム・グリッパーの初期姿勢(teleop 起動直後の /joint_states の値)
ARM_HOME="[0.0, 0.0, 0.0, 0.0]"
HAND_HOME="-0.5236"

# -------------------------------------------------------------

BAG_PID=""

# Ctrl+C で中断されても rosbag を正しく閉じる
cleanup() {
  if [ -n "$BAG_PID" ] && kill -0 "$BAG_PID" 2>/dev/null; then
    echo "rosbag を停止しています..."
    kill -INT "$BAG_PID"
    wait "$BAG_PID"
  fi
  exit 1
}
trap cleanup INT TERM

# キューブの現在位置を取得して初期位置として保存
capture_cube_pose() {
  local line
  line=$(ign model -m "$OBJ" -p 2>/dev/null | grep -A1 "Pose" | tail -1 | tr -d '[]')
  read -r x y z <<< "$line"
  local num='^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$'
  if [[ $x =~ $num && $y =~ $num && $z =~ $num ]]; then
    CUBE_X=$x; CUBE_Y=$y; CUBE_Z=$z
    echo "キューブ初期位置を取得: x=$CUBE_X y=$CUBE_Y z=$CUBE_Z"
  else
    echo "【注意】キューブ位置の自動取得に失敗。設定値を使います: x=$CUBE_X y=$CUBE_Y z=$CUBE_Z"
  fi
}

# シーンを初期状態に戻す
reset_scene() {
  # 1) グリッパーを開く(キューブを持ったままアームが動かないように先に)
  ros2 topic pub --once /crane_plus_gripper_controller/joint_trajectory \
    trajectory_msgs/msg/JointTrajectory \
    "{joint_names: [crane_plus_joint_hand],
      points: [{positions: [$HAND_HOME], time_from_start: {sec: 1}}]}" > /dev/null
  sleep 1.5

  # 2) アームを初期姿勢へ
  ros2 topic pub --once /crane_plus_arm_controller/joint_trajectory \
    trajectory_msgs/msg/JointTrajectory \
    "{joint_names: [crane_plus_joint1, crane_plus_joint2, crane_plus_joint3, crane_plus_joint4],
      points: [{positions: $ARM_HOME, time_from_start: {sec: 2}}]}" > /dev/null
  sleep 3

  # 3) キューブを初期位置へ
  ign service -s /world/$WORLD/set_pose \
    --reqtype ignition.msgs.Pose --reptype ignition.msgs.Boolean --timeout 2000 \
    --req "name: \"$OBJ\", position: {x: $CUBE_X, y: $CUBE_Y, z: $CUBE_Z}, orientation: {w: 1}" > /dev/null
  sleep 1
}

# -------------------------------------------------------------

if [ ! -f "$EXPECT_SCRIPT1" ]; then
  echo "エラー: $EXPECT_SCRIPT1 が見つかりません"
  exit 1
fi
if [ ! -f "$EXPECT_SCRIPT2" ]; then
  echo "エラー: $EXPECT_SCRIPT2 が見つかりません"
  exit 1
fi


#mkdir -p "$OUT_DIR"
echo "保存先: $OUT_DIR"

capture_cube_pose

for ((ep=0; ep<N_EPISODES; ep++)); do
  name=$(printf "ep%d" $ep)
  echo "=== $name ($((ep+1))/$N_EPISODES) ==="

  reset_scene

  # 記録開始
  ros2 bag record -o "$OUT_DIR/$name" $TOPICS > "$OUT_DIR/${name}_record.log" 2>&1 &
  BAG_PID=$!
  sleep 2

  # 自動操作
  expect "$EXPECT_SCRIPT1"
  expect "$EXPECT_SCRIPT2"

  # 記録停止(SIGINT で正しく閉じる)
  sleep 1
  kill -INT "$BAG_PID"
  wait "$BAG_PID"
  BAG_PID=""

  echo "$name 完了"
done

reset_scene
echo "全 $N_EPISODES エピソードの記録が完了しました: $OUT_DIR"done

