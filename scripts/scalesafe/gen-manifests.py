#!/usr/bin/env python3
"""Generate the ScaleSafe GitOps manifests (gitops/apps/scalesafe/base + overlays/dev).

Written from scratch for this platform (no files copied from the application repos' deploy/infra).
Re-run after adding a service:   python scripts/scalesafe/gen-manifests.py
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASE = os.path.join(ROOT, "gitops", "apps", "scalesafe", "base")
DEV = os.path.join(ROOT, "gitops", "apps", "scalesafe", "overlays", "dev")
os.makedirs(BASE, exist_ok=True)
os.makedirs(DEV, exist_ok=True)

# name, database role, extra env (value or a key of ConfigMap scalesafe-urls prefixed with '@')
SERVICES = [
    ("orchestrator", "orchestrator", []),
    ("client-service", "clients", []),
    ("kyc-service", "kyc", []),
    ("investor-service", "investors", [("SCALESAFE_INVESTOR_PUBLIC_APP_URL", "@APP_PUBLIC_URL")]),
    ("verification-service", "verification", [("SCALESAFE_PROVIDERS_MODE", "sandbox")]),
    ("esign-service", "esign", [("SCALESAFE_ESIGN_PUBLIC_APP_URL", "@APP_PUBLIC_URL"),
                                ("SCALESAFE_PROVIDERS_MODE", "sandbox")]),
]
WEB = [("app", "scalesafe-app"), ("admin", "scalesafe-admin")]
IMAGES = [s[0] for s in SERVICES] + ["app", "admin", "site"]

POD_SEC = """      securityContext:
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
"""
CTR_SEC = """          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: ["ALL"]}
"""


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def service_yaml(name, role, extra):
    env = [
        '{name: SPRING_DATASOURCE_URL, value: "jdbc:postgresql://postgres:5432/scalesafe"}',
        f"{{name: SPRING_DATASOURCE_USERNAME, value: {role}}}",
        f"{{name: SPRING_DATASOURCE_PASSWORD, valueFrom: {{secretKeyRef: {{name: scalesafe-db, key: {role}}}}}}}",
        f"{{name: SCALESAFE_SECURITY_CLIENT_ID, value: {name}}}",
        f"{{name: SCALESAFE_SECURITY_CLIENT_SECRET, valueFrom: {{secretKeyRef: {{name: scalesafe-oidc, key: {name}}}}}}}",
        "{name: SCALESAFE_SECURITY_ISSUER, valueFrom: {configMapKeyRef: {name: scalesafe-urls, key: OIDC_ISSUER}}}",
        '{name: SCALESAFE_SECURITY_JWKS_URI, value: "http://keycloak:8080/realms/scalesafe/protocol/openid-connect/certs"}',
        '{name: SCALESAFE_SECURITY_TOKEN_URI, value: "http://keycloak:8080/realms/scalesafe/protocol/openid-connect/token"}',
        "{name: SCALESAFE_CORS_ALLOWED_ORIGINS, valueFrom: {configMapKeyRef: {name: scalesafe-urls, key: CORS_ORIGINS}}}",
        '{name: JAVA_TOOL_OPTIONS, value: "-XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError"}',
        # Downgrade guard. Flyway's default ignores "future" migrations, so an OLDER image silently runs
        # against a NEWER schema and can write rows the newer code cannot use (found in the 2026-11-16
        # downgrade test: esign requests without signing_documents). Only pending migrations are ignored
        # now, so an image older than the schema fails at startup and the rollout stops (see strategy).
        '{name: SPRING_FLYWAY_IGNORE_MIGRATION_PATTERNS, value: "*:pending"}',
    ]
    if name != "orchestrator":
        env += [
            '{name: SCALESAFE_SAGA_ORCHESTRATOR_URL, value: "http://orchestrator:8080"}',
            f"{{name: SCALESAFE_SAGA_SERVICE_NAME, value: {name}}}",
            f'{{name: SCALESAFE_SAGA_BASE_URL, value: "http://{name}:8080"}}',
        ]
    for k, v in extra:
        if v.startswith("@"):
            env.append(f"{{name: {k}, valueFrom: {{configMapKeyRef: {{name: scalesafe-urls, key: {v[1:]}}}}}}}")
        else:
            env.append(f"{{name: {k}, value: {v}}}")
    env_block = "".join(f"            - {e}\n" for e in env)
    return f"""---
apiVersion: v1
kind: Service
metadata:
  name: {name}
spec:
  selector: {{app.kubernetes.io/name: {name}}}
  ports:
    - {{name: http, port: 8080, targetPort: 8080}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}
spec:
  replicas: 1
  revisionHistoryLimit: 5
  # Never take the running version down before the new one is Ready: a bad image (or one blocked by
  # the downgrade guard) leaves the old pod serving, and Argo CD reports the rollout as Degraded.
  strategy:
    type: RollingUpdate
    rollingUpdate: {{maxUnavailable: 0, maxSurge: 1}}
  progressDeadlineSeconds: 600
  selector:
    matchLabels: {{app.kubernetes.io/name: {name}}}
  template:
    metadata:
      labels: {{app.kubernetes.io/name: {name}, app.kubernetes.io/part-of: scalesafe, scalesafe.io/tier: service}}
    spec:
      automountServiceAccountToken: false
{POD_SEC}      initContainers:
        - name: wait-for-deps
          image: docker.io/library/busybox:1.37.0
          command: ["sh", "-c", "until nc -z postgres 5432 && nc -z keycloak 8080; do echo waiting; sleep 3; done"]
{CTR_SEC}            runAsUser: 65534
          resources:
            requests: {{cpu: 10m, memory: 16Mi}}
            limits: {{memory: 32Mi}}
      containers:
        - name: app
          image: scalesafe-{name}
          ports: [{{containerPort: 8080, name: http}}]
          env:
{env_block}{CTR_SEC}            readOnlyRootFilesystem: true
          startupProbe:
            httpGet: {{path: /health/liveness, port: http}}
            periodSeconds: 10
            failureThreshold: 36
          readinessProbe:
            httpGet: {{path: /health/readiness, port: http}}
            periodSeconds: 10
          livenessProbe:
            httpGet: {{path: /health/liveness, port: http}}
            periodSeconds: 20
          resources:
            requests: {{cpu: 50m, memory: 384Mi}}
            limits: {{memory: 768Mi}}
          volumeMounts:
            - {{name: tmp, mountPath: /tmp}}
      volumes:
        - {{name: tmp, emptyDir: {{}}}}
"""


def web_yaml(name, image, extra_env="", envfrom=True):
    ef = "          envFrom:\n            - configMapRef: {name: scalesafe-web-config}\n" if envfrom else ""
    return f"""---
apiVersion: v1
kind: Service
metadata:
  name: {name}
spec:
  selector: {{app.kubernetes.io/name: {name}}}
  ports:
    - {{name: http, port: 8080, targetPort: 8080}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}
spec:
  replicas: 1
  selector:
    matchLabels: {{app.kubernetes.io/name: {name}}}
  template:
    metadata:
      labels: {{app.kubernetes.io/name: {name}, app.kubernetes.io/part-of: scalesafe, scalesafe.io/tier: web}}
    spec:
      automountServiceAccountToken: false
{POD_SEC}      containers:
        - name: web
          image: {image}
          ports: [{{containerPort: 8080, name: http}}]
{ef}{extra_env}{CTR_SEC}          readinessProbe:
            httpGet: {{path: /health, port: http}}
          resources:
            requests: {{cpu: 10m, memory: 32Mi}}
            limits: {{memory: 128Mi}}
"""


POSTGRES = """# Postgres 17: one database, one schema + login role per service (each service owns its schema).
# Passwords come from Secret scalesafe-db (scripts/scalesafe/secrets.sh generates them; never in git).
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init
data:
  10-roles.sh: |
    #!/bin/sh
    # Runs once on an empty data directory.
    set -eu
    mk() {
      psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v role="$1" -v pw="$2" <<'SQL'
    CREATE ROLE :"role" LOGIN PASSWORD :'pw';
    CREATE SCHEMA :"role" AUTHORIZATION :"role";
    ALTER ROLE :"role" SET search_path = :"role";
    SQL
    }
    mk orchestrator "$PW_ORCHESTRATOR"
    mk clients      "$PW_CLIENTS"
    mk kyc          "$PW_KYC"
    mk investors    "$PW_INVESTORS"
    mk verification "$PW_VERIFICATION"
    mk esign        "$PW_ESIGN"
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC;"
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector: {app.kubernetes.io/name: postgres}
  ports:
    - {name: postgres, port: 5432, targetPort: 5432}
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels: {app.kubernetes.io/name: postgres}
  template:
    metadata:
      labels: {app.kubernetes.io/name: postgres, app.kubernetes.io/part-of: scalesafe}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        fsGroup: 70
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: postgres
          image: docker.io/library/postgres:17-alpine
          ports: [{containerPort: 5432}]
          env:
            - {name: POSTGRES_DB, value: scalesafe}
            - {name: POSTGRES_USER, value: postgres}
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
            - {name: POSTGRES_PASSWORD, valueFrom: {secretKeyRef: {name: scalesafe-db, key: postgres}}}
            - {name: PW_ORCHESTRATOR, valueFrom: {secretKeyRef: {name: scalesafe-db, key: orchestrator}}}
            - {name: PW_CLIENTS, valueFrom: {secretKeyRef: {name: scalesafe-db, key: clients}}}
            - {name: PW_KYC, valueFrom: {secretKeyRef: {name: scalesafe-db, key: kyc}}}
            - {name: PW_INVESTORS, valueFrom: {secretKeyRef: {name: scalesafe-db, key: investors}}}
            - {name: PW_VERIFICATION, valueFrom: {secretKeyRef: {name: scalesafe-db, key: verification}}}
            - {name: PW_ESIGN, valueFrom: {secretKeyRef: {name: scalesafe-db, key: esign}}}
""" + CTR_SEC + """          readinessProbe:
            exec: {command: ["pg_isready", "-U", "postgres", "-d", "scalesafe"]}
            periodSeconds: 5
          resources:
            requests: {cpu: 50m, memory: 128Mi}
            limits: {memory: 512Mi}
          volumeMounts:
            - {name: data, mountPath: /var/lib/postgresql/data}
            - {name: init, mountPath: /docker-entrypoint-initdb.d}
            - {name: run, mountPath: /var/run/postgresql}
      volumes:
        - {name: init, configMap: {name: postgres-init, defaultMode: 0555}}
        - {name: run, emptyDir: {}}
  volumeClaimTemplates:
    - metadata: {name: data}
      spec:
        accessModes: [ReadWriteOnce]
        resources: {requests: {storage: 5Gi}}
"""

KEYCLOAK = """# Keycloak. Dev mode: start-dev + realm import from ConfigMap scalesafe-realm (created by
# scripts/scalesafe/secrets.sh from the application repo; it is application config, not infra).
# Production: `start` with Postgres as its DB, TLS and a real hostname.
apiVersion: v1
kind: Service
metadata:
  name: keycloak
spec:
  selector: {app.kubernetes.io/name: keycloak}
  ports:
    - {name: http, port: 8080, targetPort: 8080}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector:
    matchLabels: {app.kubernetes.io/name: keycloak}
  template:
    metadata:
      labels: {app.kubernetes.io/name: keycloak, app.kubernetes.io/part-of: scalesafe}
    spec:
      automountServiceAccountToken: false
""" + POD_SEC + """      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:26.0.7
          args: ["start-dev", "--import-realm"]
          ports: [{containerPort: 8080, name: http}, {containerPort: 9000, name: mgmt}]
          env:
            - {name: KC_BOOTSTRAP_ADMIN_USERNAME, value: admin}
            - {name: KC_BOOTSTRAP_ADMIN_PASSWORD, valueFrom: {secretKeyRef: {name: scalesafe-keycloak, key: admin-password}}}
            - {name: KC_HOSTNAME, valueFrom: {configMapKeyRef: {name: scalesafe-urls, key: KEYCLOAK_PUBLIC_URL}}}
            - {name: KC_HOSTNAME_BACKCHANNEL_DYNAMIC, value: "true"}
            - {name: KC_HEALTH_ENABLED, value: "true"}
""" + CTR_SEC + """          startupProbe:
            httpGet: {path: /health/started, port: mgmt}
            periodSeconds: 10
            failureThreshold: 40
          readinessProbe:
            httpGet: {path: /health/ready, port: mgmt}
            periodSeconds: 10
          resources:
            requests: {cpu: 100m, memory: 512Mi}
            limits: {memory: 1Gi}
          volumeMounts:
            - {name: realm, mountPath: /opt/keycloak/data/import, readOnly: true}
      volumes:
        - {name: realm, configMap: {name: scalesafe-realm}}
"""

NETWORK = """# Default-deny ingress; allow traffic inside the namespace and from the ingress controller to web pods.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - podSelector: {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-controller
spec:
  podSelector:
    matchLabels: {scalesafe.io/tier: web}
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: kube-system}
"""

write(os.path.join(BASE, "postgres.yaml"), POSTGRES)
write(os.path.join(BASE, "keycloak.yaml"), KEYCLOAK)
write(os.path.join(BASE, "network.yaml"), NETWORK)
write(os.path.join(BASE, "services.yaml"),
      "# Six Spring Boot services: restricted pods, read-only root FS, Spring health probes,\n"
      "# init container waits for Postgres + Keycloak.\n"
      + "".join(service_yaml(*s) for s in SERVICES))
web = "".join(web_yaml(f"web-{n}", f"scalesafe-{n}",
                       f"          env:\n            - {{name: SCALESAFE_OIDC_CLIENT_ID, value: {c}}}\n")
              for n, c in WEB)
web += web_yaml("site", "scalesafe-site", envfrom=False)
write(os.path.join(BASE, "web.yaml"),
      "# Client portal + admin console (React/Vite on unprivileged nginx) and the corporate site.\n" + web)
write(os.path.join(BASE, "kustomization.yaml"), """apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - network.yaml
  - postgres.yaml
  - keycloak.yaml
  - services.yaml
  - web.yaml
""")
write(os.path.join(DEV, "kustomization.yaml"), """# ScaleSafe dev environment. Tekton's gitops-update-image task rewrites each newTag after a build.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: scalesafe
resources:
  - ../../base
configMapGenerator:
  # Public URLs as the browser sees them. Dev without a domain = kubectl port-forward on localhost.
  - name: scalesafe-urls
    literals:
      - KEYCLOAK_PUBLIC_URL=http://localhost:8180
      - OIDC_ISSUER=http://localhost:8180/realms/scalesafe
      - APP_PUBLIC_URL=http://localhost:5173
      - CORS_ORIGINS=http://localhost:5173,http://localhost:5174
  - name: scalesafe-web-config
    literals:
      - SCALESAFE_OIDC_AUTHORITY=http://localhost:8180/realms/scalesafe
      - SCALESAFE_API_ORCHESTRATOR=http://localhost:8081
      - SCALESAFE_API_CLIENTS=http://localhost:8082
      - SCALESAFE_API_KYC=http://localhost:8083
      - SCALESAFE_API_INVESTORS=http://localhost:8084
      - SCALESAFE_API_VERIFICATION=http://localhost:8085
      - SCALESAFE_API_ESIGN=http://localhost:8086
images:
""" + "".join(f"""  - name: scalesafe-{i}
    newName: ghcr.io/__GITHUB_ORG__/scalesafe-{i}
    newTag: "latest"
""" for i in IMAGES))
print("manifests written:", BASE, DEV)
