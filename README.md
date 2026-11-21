# 짝짜꿍 Database

구본혁이 Supabase PostgreSQL의 스키마·권한·마이그레이션을 관리합니다. 적용할 마이그레이션은 `supabase/migrations/`에 두고, 기존 DB 상태를 확인한 뒤 적용합니다. 설계 DBML은 `docs/schema.dbml`을 참고합니다. 개발 브랜치는 `server`입니다.

## 협업 순서

역할 브랜치에서 변경하고 이 저장소의 `main`을 대상으로 PR을 엽니다. PR에 직접 확인한 동작과 결과, 다음 담당자가 받을 값을 적습니다. 우영이 검토·병합하고 구본혁이 병합된 버전을 배포합니다. 팀 배포팩의 `frontend/`, `backend/`는 해당 저장소 루트를 뜻합니다. DB 변경은 Database 저장소로 보냅니다.

[팀 노션과 역할 카드](https://tasteful-fight-7cd.notion.site/41d58907758380bdb941e7781b7096af) · [Frontend](https://github.com/JJak-JJak-GGeung/JJak-JJak-GGeung-Frontend) · [Backend](https://github.com/JJak-JJak-GGeung/JJak-JJak-GGeung-Backend)

공개 A 자료는 팀 배포팩에서 사용합니다. 로컬 환경 파일·인증 키·B 입력과 정답표는 팀 저장소 밖에 보관합니다.
