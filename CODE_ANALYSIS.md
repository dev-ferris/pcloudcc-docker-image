# Codeanalyse & Security-Review

Stand: 2026-07-18 · Analysierter Stand: `main` · Werkzeuge: manuelles Review,
shellcheck 0.9.0 (`--shell=sh`, clean bis `--severity=info`), praktische
Verifikation einzelner Fixes (oathtool-stdin).

> **Umsetzungsstatus:** Die Punkte **#1, #2, #3, #6, #7, #9, #10 und #11**
> sind auf diesem Branch umgesetzt und getestet (shellcheck clean,
> YAML-validiert, oathtool-stdin- und MOUNT_TIMEOUT-Validierung funktional
> geprüft). Offen bleiben die bewusst zurückgestellten Punkte #4, #5, #8
> und #12.

## Gesamturteil

Das Repository ist bereits auf sehr hohem Niveau: Multi-Stage-Build,
`cap_drop: ALL` mit minimalem Add-back, `read_only`-Rootfs,
`no-new-privileges`, `*_FILE`-Secret-Support, Pfad-Validierung vor
`chown -R`, Trivy-Gate vor dem Push, Cosign-Signierung, SBOM + Provenance,
SHA-gepinnte GitHub Actions, Dependabot. Die folgenden Punkte sind
Feinschliff, keine kritischen Lücken.

**Explizit geprüft und für gut befunden:**

- `eval`-Konstruktion in `load_secret_file()` — Variablennamen sind
  Caller-kontrolliert, Dateiinhalte werden als Assignment-Wert nicht
  re-geparst → sicher.
- Crypto-Passwort wird via `printf`-Builtin gepipet (`entrypoint.sh:310`) —
  erscheint *nicht* in der Prozessliste.
- `validate_mount_path()` schützt das rekursive `chown` wirksam.
- `.dockerignore` schließt `.env` aus.
- Workflows: Login-/Push-Steps werden bei `pull_request` übersprungen —
  keine Secret-Exposition gegenüber Fork-PRs.

---

## Befunde

### 🔒 Sicherheit

| # | Befund | Schwere | Ort |
|---|--------|---------|-----|
| 1 | **TOTP-Secret als CLI-Argument.** `oathtool --totp -b "${PCLOUD_TOTP_SECRET}"` macht das Secret kurzzeitig in `/proc/<pid>/cmdline` sichtbar. Verifizierter Fix: per stdin übergeben — `printf '%s' "$SECRET" \| oathtool --totp -b -` liefert identische Codes. Abgemildert durch den isolierten PID-Namespace (nur root im Container), aber Defense-in-Depth zum Nulltarif. | Niedrig | `entrypoint.sh:120` |
| 2 | **Irreführende OCI-Labels bei lokalem Build.** `licenses="BSD-3-Clause"` und `source=lneely/…` beschreiben den Upstream, nicht dieses Image (MIT). Die CI-`metadata-action` überschreibt das für publizierte Images; lokal gebaute Images tragen die falschen Metadaten. | Kosmetisch | `Dockerfile:41-44` |
| 3 | **`MOUNT_TIMEOUT` unvalidiert.** Ein nicht-numerischer Wert lässt das Skript erst in `wait_for_mount()` an der Arithmetik sterben (`set -e`, kryptische Meldung). Numerische Validierung in `validate_inputs()` analog UID/GID. | Härtung | `entrypoint.sh:52-78` |
| 4 | **`apparmor:unconfined`.** Dokumentierter Trade-off (FUSE); ein FUSE-spezifisches Profil wäre möglich, ist aber host-spezifisch. Kein Handlungszwang. | Info | `docker-compose.yml:24` |
| 5 | **`PCLOUDCC_REF=main` = Moving Target.** Trivy/Cosign/Provenance vorhanden; ergänzend könnte der Build den tatsächlich gebauten Upstream-SHA loggen bzw. als Image-Label (`pcloudcc.upstream.revision`) einbrennen — dann ist pro Image nachvollziehbar, welcher Upstream-Stand enthalten ist. | Nice-to-have | `Dockerfile:31-36` |

### ⚙️ Robustheit

| # | Befund | Ort |
|---|--------|-----|
| 6 | **Shutdown-Race mit Docker.** `stop_pcloudcc()` gewährt bis zu 10 s Grace — Dockers Default-`stop_grace_period` ist ebenfalls 10 s. Docker kann per SIGKILL zuschlagen, bevor `fusermount -u` läuft → hängende FUSE-Mounts auf dem Host (exakt das im README beschriebene Troubleshooting-Symptom). Fix: `stop_grace_period: 30s` in `docker-compose.yml`. | `entrypoint.sh:146-161`, `docker-compose.yml` |
| 7 | **Kein Init-Prozess.** Die Shell läuft als PID 1 und reaped nur eigene Kinder. `init: true` in Compose (tini) als Ein-Zeilen-Absicherung. | `docker-compose.yml` |
| 8 | **Stiller bindfs-Ausfall.** Schlägt `wait_for_mount` in der bindfs-Subshell fehl, läuft der Container ohne Overlay weiter. Der Healthcheck meldet unhealthy, aber Docker startet bei unhealthy standardmäßig nicht neu. | `entrypoint.sh:321-329` |

### 🚀 Build/CI-Optimierung

| # | Befund | Ort |
|---|--------|-----|
| 9 | **`make` ohne Parallelisierung.** Single-threaded — besonders teuer für arm64/arm-v7 unter QEMU. **Parallel-Safety getestet und bestätigt** (siehe unten): `make -j"$(nproc)"` ist sicher und brachte im Test einen 4,2×-Speedup. | `Dockerfile:35` |
| 10 | **Smoke-Test läuft nach dem Push.** Ein funktional kaputtes Image ist zum Testzeitpunkt bereits als `latest` publiziert; der Trivy-Gate greift vor dem Push, der Funktionstest nicht. Besser: Smoke-Test gegen das vorhandene `/tmp/scan-image.tar` (`docker load`) vor den Push-Step ziehen. | `docker-build.yml:195-213` |
| 11 | **Fehlende `timeout-minutes`.** Hängende (QEMU-)Builds blockieren den Runner bis zum 6-h-GitHub-Default. Z. B. 120 min für Build, 10 min für Lint/Check. | alle Workflows |
| 12 | **check-upstream Cache-Eviction.** Actions-Caches verfallen nach ~7 Tagen Nichtnutzung → derselbe Upstream-SHA kann erneut einen Build triggern. Harmlos (wöchentlicher Rebuild existiert ohnehin). | `check-upstream.yml` |

---

## Umsetzungsempfehlung

### Klar empfohlen (geringes Risiko, klarer Nutzen)

| Prio | Punkt | Aufwand | Begründung |
|------|-------|---------|------------|
| 1 | #6 `stop_grace_period: 30s` | 1 Zeile | Verhindert ein real dokumentiertes Problem (hängende FUSE-Mounts). |
| 2 | #1 oathtool via stdin | 1 Zeile | Verifizierter, kostenloser Sicherheitsgewinn. |
| 3 | #10 Smoke-Test vor Push | Umstellung eines CI-Steps | Verhindert Publikation funktional kaputter Images unter `latest`. |
| 4 | #3 `MOUNT_TIMEOUT`-Validierung | ~4 Zeilen | Konsistenz mit bestehender UID/GID-Validierung. |
| 5 | #11 `timeout-minutes` | wenige Zeilen | CI-Hygiene, kein Verhaltensrisiko. |
| 6 | #7 `init: true` | 1 Zeile | Zombie-Reaping-Absicherung. |
| 7 | #2 OCI-Label-Korrektur | 2 Zeilen | Korrekte Metadaten auch bei lokalem Build. |

### Zusätzlich empfohlen nach Test

- **#9 `make -j"$(nproc)"`:** Getestet am 2026-07-18 gegen Upstream-Commit
  `93a99cd6` (mbedTLS 3.6.2, gcc 13, Ubuntu 24.04, 4 Kerne):
  - *Strukturanalyse:* Jede Objektdatei hat genau eine Pattern-Rule, der
    finale Link hängt von allen Objekten ab, `$(shell …)`-Aufrufe laufen
    einmalig zur Parse-Zeit, keine Basename-Kollisionen zwischen
    `pclsync/*.c` (68 Dateien) und `*.cpp` (4 Dateien) trotz flacher
    `notdir`-Objektablage.
  - *Empirie:* 3× `make -j4` und 2× Stress-Test `make -j16` (erzwungene
    maximale Überlappung bei 4 Kernen) — alle 5 Läufe erfolgreich, Binary
    jeweils **byteidentisch** zum seriellen Build (gleiche SHA-256).
  - *Speedup:* seriell 39,4 s → parallel 9,4 s (**4,2×** bei 4 Kernen);
    unter QEMU-Emulation (arm64/arm-v7) ist ein ähnlicher Faktor zu
    erwarten.
  - *Umsetzung:* In `Dockerfile:35` `make` durch `make -j"$(nproc)"`
    ersetzen.

### Bedingt empfohlen

- **#5 Upstream-SHA-Label:** Nice-to-have für Nachvollziehbarkeit;
  moderater Aufwand (ARG/LABEL-Durchreichung oder SHA-Ermittlung im
  Build-Stage).

### Nicht empfohlen / bewusst offen lassen

- **#4 AppArmor-Profil:** host-spezifisch, im README bereits sauber als
  Trade-off dokumentiert.
- **#8 bindfs-Ausfall:** Aufwand/Nutzen ungünstig; der Healthcheck deckt
  den Zustand ab. Allenfalls README-Hinweis auf `autoheal` o. Ä.
- **#12 Cache-Eviction:** harmlos, wöchentlicher Rebuild fängt es ab.
