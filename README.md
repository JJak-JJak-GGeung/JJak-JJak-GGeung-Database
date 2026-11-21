# 짝짜꿍 Database

짝짜꿍은 식자재를 납품받는 점주가 사진으로 올린 명세서·수령 기록·청구서를 한곳에서 대조하는 서비스입니다. 거래처와 통화한 내용은 전사 초안을 고쳐 해당 거래의 메모로 남길 수 있습니다. 점주는 차이가 난 품목과 원본을 확인하고 정산을 직접 승인합니다.

## 심사위원용 시연

[합성 예시 사진 A01~A05 다운로드](https://raw.githubusercontent.com/JJak-JJak-GGeung/JJak-JJak-GGeung-Frontend/main/docs/demo/jjakjjakggeung-demo-a01-a05.zip) · [배포 앱 열기](https://jjak-jjak-ggeung-frontend.vercel.app/)

처음 방문한 브라우저에는 저장된 점포와 거래가 없습니다. 회원가입 없이 사진으로 새 점포와 거래처를 만들 수 있습니다.

1. 예시 ZIP을 풀고 배포 앱 오른쪽 아래 **+ → 사진 올리기**에서 `A02_납품명세_1113.png`를 선택합니다.
2. **원본 보기**에서 명세 번호 `DL-A131`, 첫 품목 `40kg`, 단가 `20,000원/kg`을 판독값과 대조합니다.
3. **가온 장어식당**을 내 점포로, **달마루 수산**을 거래처로 선택하거나 새로 등록합니다. **납품 명세서**, 정산 주 **2026-11-09~11-15**를 선택하고 저장한 뒤, 정산 화면에서 문서와 원본을 다시 엽니다.

[전체 시연 안내](https://github.com/JJak-JJak-GGeung/JJak-JJak-GGeung-Frontend/blob/main/docs/DEMO.md)에서 수령 확인부터 승인본 재조회까지 볼 수 있습니다.

## 구성

| 저장소 | 역할 |
| --- | --- |
| [Frontend](https://github.com/JJak-JJak-GGeung/JJak-JJak-GGeung-Frontend) | Flutter Web 화면, 사진·통화녹음 입력, 판독값 검수, 주간 정산 조회 |
| [Backend](https://github.com/JJak-JJak-GGeung/JJak-JJak-GGeung-Backend) | FastAPI, 사진 판독과 음성 전사, 수령·청구 대조 및 승인 처리 |
| [Database](https://github.com/JJak-JJak-GGeung/JJak-JJak-GGeung-Database) | Supabase PostgreSQL 스키마, 원본 보관, 확인 이력과 승인본 저장 |

이 저장소는 Supabase PostgreSQL 스키마와 마이그레이션을 관리합니다. 점포·거래처·주간 정산, 사진 원본의 위치, 수령·청구 근거, 확인한 메모와 승인 당시 스냅샷을 저장합니다. 배포 앱은 Backend API를 통해 업무 데이터를 조회하고 저장합니다.

[마이그레이션](./supabase/migrations) · [스키마 설계](./docs/schema.dbml) · [DB 계약과 통합 검증](./docs/OPERATIONS.md)
