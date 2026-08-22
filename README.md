# coding-api — R 실행·채점 서버

`coding-test` 프런트엔드가 호출하는 Plumber API입니다. 학생 코드 실행, 그래프 캡처,
tracker 기반 정답 확인, 학습 이벤트 기록을 담당합니다.

## v2에서 달라진 점

| 항목 | 이전 | 지금 |
|------|------|------|
| 실행 환경 | 매 요청마다 새 환경 | 수강자별 세션 환경 유지 → 앞 단계에서 만든 `model_df` 등을 뒤 단계에서 그대로 사용 |
| 출력 | 마지막 표현식만 출력 | `evaluate`로 모든 최상위 표현식을 순서대로 출력 |
| 그래프 | 없음 | 여러 장을 base64 PNG 배열로 반환 (`plots`) |
| 채점 | 프런트엔드 전용 | `/check`에서 tracker의 `check("id")`를 서버 실행 |
| 데이터 | 학생 코드가 매번 다운로드 | 이미지에 미리 포함, 코드에서는 `DATA("ohie_all6m.rds")` |

## 엔드포인트

| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET  | `/health` | 상태·활성 세션 수·보유 데이터 |
| POST | `/init` | `{sid, session, tracker, student}` — 세션 환경 생성, tracker 로드 |
| POST | `/run` | `{code, sid, session}` — 실행. `{success, output, error, plots[], fresh}` |
| POST | `/check` | `{sid, session, check_id}` — `{available, passed, feedback}` |
| POST | `/reset` | 세션 환경 삭제 |
| POST | `/track` | 학습 이벤트 저장 |
| GET  | `/dashboard/data` | 세션별 완료율·리더보드 |
| GET  | `/export` | 전체 이벤트 CSV |

`sid`는 브라우저가 만든 익명 식별자, `student`는 수강자가 입력한 ID입니다.

## 환경 변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `DATA_DIR` | `/app/data` | 실습 데이터·tracker 캐시·SQLite 경로 |
| `SESSION_TTL` | `5400` | 세션 환경 유지 시간(초) |
| `MAX_SESSIONS` | `60` | 동시 유지 세션 수 상한 |
| `RUN_TIME_LIMIT` | `150` | 코드 1회 실행 제한(초) |
| `ENABLE_KERAS` | `false` | Keras 로드 여부 |

## 배포 (Render)

1. 이 폴더를 `coding-api` 저장소에 push
2. Render → New → Web Service → Runtime **Docker**
3. 첫 빌드는 15~25분 (패키지 컴파일)
4. 배포된 URL을 `coding-test/courses.js`의 `API_URL`에 반영

### 꼭 알아둘 점

- **메모리.** 무료 플랜(512MB)으로는 수강자 여러 명의 세션 환경을 동시에 유지하기 어렵습니다.
  워크숍 당일에는 최소 Starter(2GB) 이상을 권장합니다. `MAX_SESSIONS`로 상한을 조절하세요.
- **Keras/TensorFlow.** `--build-arg ENABLE_KERAS=true`로 빌드하면 이미지가 3GB 이상이 되고
  학습 1회에 수백 MB를 씁니다. 2강 Part 2 이후를 온라인으로 돌리려면 이 세션만 별도
  인스턴스로 띄우는 편이 안전합니다. 켜지 않으면 Part 1(직접 구현)까지는 그대로 동작하고
  Keras 단계에서만 "패키지 없음" 오류가 납니다.
- **슬립.** 무료 플랜은 15분 미사용 시 잠들고, 이때 세션 환경도 사라집니다.
  프런트엔드는 이 경우 `fresh: true`를 받아 "데이터 준비 단계를 다시 실행하세요"라고 안내합니다.
- **영속 디스크.** `tracking.db`를 유지하려면 Render Disk를 `/app/data`에 붙이세요.
  붙이지 않으면 재배포마다 기록이 초기화됩니다(실습 데이터는 이미지에 있으므로 무관).

## 학생 코드에서 막아 둔 함수

`system`, `shell`, `unlink`, `file.remove`, `Sys.setenv`, `download.file`, `source`,
`eval(parse`, `install.packages`, `file.rename`, `q()`, `quit()` — 그리고 빈칸(`_____`)이
남아 있는 코드는 실행되지 않습니다.

데이터는 `DATA("파일명")` 헬퍼로 접근합니다. 새 실습 데이터를 추가하려면
Dockerfile의 `ADD` 줄을 늘리면 됩니다.
