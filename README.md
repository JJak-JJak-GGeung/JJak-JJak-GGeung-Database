# 짝짜꿍 Database

식당 점주의 식자재 대금 대조·승인 서비스 **짝짜꿍**의 Supabase PostgreSQL 스키마입니다. 원본 문서, 판독 행, 수령 확인, 통화 메모, 승인본을 저장하고 **중복 반영·동시 승인을 DB 트랜잭션으로 막습니다.**

**🔗 서비스: https://jjak-jjak-ggeung-frontend.vercel.app** · 체험 방법은 [Frontend README](https://github.com/JJak-JJak-GGeung/JJak-JJak-GGeung-Frontend#2분-체험)에 있습니다.

| 저장소 | 내용 |
| --- | --- |
| [Frontend](https://github.com/JJak-JJak-GGeung/JJak-JJak-GGeung-Frontend) | Flutter Web 점주 화면 · 예시 자료 |
| [Backend](https://github.com/JJak-JJak-GGeung/JJak-JJak-GGeung-Backend) | FastAPI · 사진 판독 · 음성 전사 · 대조 계산 |
| **Database (여기)** | Supabase PostgreSQL 스키마 · 승인 트랜잭션 |

## 핵심 보장

| 보장 | 방법 |
| --- | --- |
| 근거가 바뀌면 이전 계산으로 승인할 수 없음 | 근거 변경 시 기간 `input_revision` 증가, 지난 버전 요청은 `409 STALE_REVISION` |
| 같은 요청은 한 번만 반영 | 요청 키 기록 — 재시도는 당시 응답, 같은 키 다른 본문은 `409 KEY_REUSE` |
| 동시에 두 번 승인해도 승인본 1건 | 기간 잠금 + 버전 유일 제약 |
| 승인 당시 근거 보존 | 승인 스냅샷·확인·메모·수령 기록은 수정·삭제 불가 트리거 |
| 미해결 차이가 있으면 승인 불가 | `422 BLOCKED`와 차단 사유 |
| 확인한 글만 저장 | 통화 메모는 점주가 확인한 텍스트만, 원음은 저장하지 않음 |

스키마 설계는 [`docs/schema.dbml`](docs/schema.dbml), 마이그레이션은 [`supabase/migrations/`](supabase/migrations)에 있습니다.

## 구현된 DB 계약

팀 ERD의 17개 테이블에 기간별 원본 연결, 업로드 요청 기록, 공통 요청 기록, 확인 이력, 거래별 확인 메모를 더해 22개 테이블을 사용합니다. 기존 원본의 문서 ID·바이트 해시·Storage 경로는 유지합니다.

모든 업무 테이블은 RLS를 켜고 anon·authenticated 직접 접근을 차단합니다. 로그인 없는 현재 서비스는 FastAPI 서버가 service_role로 요청을 수행합니다. 점포 소유자와 승인자 UUID는 선택값이며, 확인·메모·승인 RPC에는 비어 있지 않은 p_actor_label이 필요합니다.

서버에서 호출할 RPC는 다음과 같습니다.

- register_document는 기존 업로드 API와 같은 인자를 사용합니다.
- save_confirmation(p_store,p_period,p_expected,p_key,p_body,p_actor_label,p_actor)는 수령 연결·수령 대체·청구 대체·행 정정을 저장합니다.
- save_confirmed_memo(p_store,p_transaction,p_text,p_mode,p_expected,p_key,p_actor_label,p_actor)는 확인한 텍스트만 보존합니다.
- finish_reconciliation(p_store,p_period,p_expected)는 서버가 거래별 대조 결과와 근거 연결을 저장한 뒤 현재 자료 버전의 계산 완료를 기록합니다.
- approve_period(p_store,p_period,p_expected,p_key,p_actor_label,p_actor)는 현재 버전·미해결 근거를 검사하고 승인 스냅샷을 고정합니다.

p_actor는 생략할 수 있습니다. PT409 STALE_REVISION은 최신 버전을, PT409 KEY_REUSE는 같은 키의 다른 본문을 나타냅니다. PT422 BLOCKED의 상세에는 차단 사유가 담깁니다. 이미 성공한 동일 요청은 당시 응답을 반환하고, 같은 기간·자료 버전의 동시 승인은 승인 ID 한 개를 반환합니다. 입력 근거가 변경되면 기간 버전이 증가하고 계산 완료 표시는 해제됩니다. 대조 결과를 새로 저장한 뒤 finish_reconciliation을 호출해야 다음 승인을 검토할 수 있습니다.

## 원격 통합 검증

팀 Supabase 계정으로 CLI 로그인과 프로젝트 연결을 완료한 뒤 python3 tests/verify_domain.py를 실행합니다.

검증은 별도 점포에서 관계·중복 요청·수령 정정·수정 청구서·동시 승인·승인 스냅샷·송금 배분을 확인합니다. 종료 시 테스트 데이터만 삭제하고 원본 문서와 Storage 메타데이터가 유지됐는지 대조합니다. 테스트용 승인·확인 이력을 정리할 때는 하나의 트랜잭션 안에서 해당 이력의 불변 트리거를 잠시 비활성화한 뒤 복구하므로, 이 스크립트는 관리 권한이 있는 검증 환경에서 실행합니다.

---

<details>
<summary>개발 기록 (팀 내부 협업 규칙)</summary>

구본혁이 Supabase PostgreSQL의 스키마·권한·마이그레이션을 관리합니다. 적용할 마이그레이션은 `supabase/migrations/`에 두고, 기존 DB 상태를 확인한 뒤 적용합니다. 설계 DBML은 `docs/schema.dbml`을 참고합니다. 개발 브랜치는 `server`입니다.

### 협업 순서

역할 브랜치에서 변경하고 이 저장소의 `main`을 대상으로 PR을 엽니다. PR에 직접 확인한 동작과 결과, 다음 담당자가 받을 값을 적습니다. 우영이 검토·병합하고 구본혁이 병합된 버전을 배포합니다. 팀 배포팩의 `frontend/`, `backend/`는 해당 저장소 루트를 뜻합니다. DB 변경은 Database 저장소로 보냅니다.

[팀 노션과 역할 카드](https://tasteful-fight-7cd.notion.site/41d58907758380bdb941e7781b7096af) · [Frontend](https://github.com/JJak-JJak-GGeung/JJak-JJak-GGeung-Frontend) · [Backend](https://github.com/JJak-JJak-GGeung/JJak-JJak-GGeung-Backend)

공개 A 자료는 팀 배포팩에서 사용합니다. 로컬 환경 파일·인증 키·B 입력과 정답표는 팀 저장소 밖에 보관합니다.

</details>
