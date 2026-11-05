#!/bin/bash
# 더블클릭: SmartBlind를 빌드해 ~/Applications 에 설치하고 실행합니다.
cd "$(dirname "$0")"
chmod +x ./build.sh
./build.sh install
status=$?
echo
if [ $status -ne 0 ]; then
  echo "빌드에 실패했습니다. 위 오류 메시지를 복사해 Claude에게 보내 주세요."
fi
read -n 1 -s -r -p "아무 키나 누르면 창을 닫습니다..."
