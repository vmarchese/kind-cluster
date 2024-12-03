# Kind Cluster creation script

The script `create_cluster.sh` creates a local kind cluster with an observability stack (i.e.: Jaeger, Prometheus, Grafana, OTEL Collector) included if asked for.


## Usage


```
    Usage: create_cluster.sh [-h] [-v] [-f] -p param_value arg1 [arg2...]

    Creates a kind cluster with observability stack if asked for.

    Available options:

    -h, --help               Print this help and exit
    -a, --address            Cluster address
    -s, --skip-create        Skip cluster creation
    -d, --domain             Cluster domain
    -n, --name               Cluster name (defaults to "kind")
    -w, --workers            Number of workers (defaults to 1, , must be >=1 )
    -r, --registry_hostname  Registry hostname (default: registry.localhost)
    -l, --log-file           Log file (default to tmp)
    -j, --jaeger             Install Jaeger
    -o, --otel               Install OpenTelemetry collector
    -p, --prometheus         Install Prometheus
    -g, --grafana            Install Grafana
    -v, --verbose            Print script debug info
    -V, --kind-verbose       Sets kind log verbosity    
```

## Examples

### 1. Create a simple cluster with default values
  - 1 worker
  - cluster address: `0.0.0.0`
  - domain: `dev.localhost`
  - issuer: `https://kubernetes.default.svc.cluster.local`

```bash
> ./create_cluster.sh
```

### 1. Create a simple cluster with default values
  - 1 worker
  - cluster address: `0.0.0.0`
  - domain: `dev.localhost`
  - issuer: `https://k8sfederation.blob.core.windows.net/kind`

```bash
> ./create_cluster.sh -i https://k8sfederation.blob.core.windows.net/kind
```

### 1. Create a cluster running on a VM on ip `192.168.1.10`:
  - 2 workers
  - cluster address: `192.168.1.10`
  - domain: `kind.me`
  - issuer: `https://kubernetes.default.svc.cluster.local`
  - Grafana, Prometheus, Jaeger and OTEL Collector enabled

```bash
> ./create_cluster.sh -a 192.168.1.10 -d kind.me -w 2 -o -g -p -j 
```

or 

```bash
> ./create_cluster.sh  \
  --address 192.168.1.10 \
  --domain kind.me \
  --workers 2 \
  --jaeger \
  --prometheus \
  --grafana \
  --otel
```

## Tutorial: pod identity with Azure Active Directory federation

1. Create the required resources on Azure
    - an Azure Storage Account (i.e. `k8sfederation`) with a public container (i.e. `kind`)
    - an application registration on Azure Active Directory (i.e. client id `3ae4dafa-ec23-44c2-bdef-1cd220cacbac` on tenant `2862cc66-157f-445b-8c5d-f5a41f314800`)

1. Create a cluster using `https://k8sfederation.blob.core.windows.net/kind` as issuer

    ```bash
    > ./create_cluster.sh -i https://k8sfederation.blob.core.windows.net/kind
    ```

1. Create a ClusterRoleBinding to enable unauthenticated calls to the oidc discovery APIs

    ```bash
    > kubectl create clusterrolebinding oidc-reviewer --clusterrole=system:service-account-issuer-discovery --group=system:unauthenticated
    ```

1. Get the openid configuration and upload it on the `.well-known/openid-configuration` blob in the Storage Account

    ```bash
    > curl -k https://localhost:6443/.well-known/openid-configuration | jq
    ```
    ```json
    {
      "issuer": "https://k8sfederation.blob.core.windows.net/kind",
      "jwks_uri": "https://k8sfederation.blob.core.windows.net/kind/openid/v1/jwks",
      "response_types_supported": [
        "id_token"
      ],
      "subject_types_supported": [
        "public"
      ],
      "id_token_signing_alg_values_supported": [
        "RS256"
      ]
    }
    ```

1. Get the cluster key set (jwks) and upload it on the `openid/v1/jwks` blob in the Storage Account

    ```bash
    > curl -k https://localhost:6443/openid/v1/jwks | jq
    ```
    ```json
    {
      "keys": [
        {
          "use": "sig",
          "kty": "RSA",
          "kid": "sN-aa7br_uJtZm97LVf6QpwFCHGSBFA-SLhNl2MQuhU",
          "alg": "RS256",
          "n": "ny7arQqGqBwppJgWFOUdzPqhGPJY02XsMEM7IM8sX2LXhS78XyeAxLoVrhiOaIcZqdgJVt5zcmjRE6A_Rr48rJ3LCS8TSPdFvoBhwu0D0sTiH_hLyD6Up3tz23UFyOau_WPTc9FUMPf4pROCLA7BjNF3Te_WhKLoMYnA6aMQDLdVfeyTRcKs2y0A8XBiQuUIhup9b-7dYV7xPN-945NUmy3H8sYDDOL2Nz3Rr23sXOvCyHWoKyDzmvLqloQ1t78tFrDssy3dI95L8GDO_-vYvWSAFwEbIqbyjz9VvtscvSTj5HWQ_R2SNOUuIKgXiKdXUM63ltN-ngIM9z_6XJYBUw",
          "e": "AQAB"
        }
      ]
    }
    ```

1. Create a pod on a given namespace (i.e. `default`) with an additional token (i.e. `/var/run/secrets/tokens/oidc-token`) for a given service account (i.e. `default`) and a given audience (i.e. `api://AzureADTokenExchange`) 

    ```yaml
    kubectl apply -f - <<EOF
    apiVersion: v1
    kind: Pod
    metadata:
      name: nginx
    spec:
      serviceAccountName: default
      containers:
        - image: nginx:alpine
          name: oidc
          volumeMounts:
            - mountPath: /var/run/secrets/tokens
              name: oidc-token
      volumes:
        - name: oidc-token
          projected:
            sources:
              - serviceAccountToken:
                  path: oidc-token
                  expirationSeconds: 7200
                  audience: api://AzureADTokenExchange
    EOF
    ```

1. Configure the federeted credentials for the target app registration and provide the following:
    - issuer url (i.e. `https://k8sfederation.blob.core.windows.net/kind`)
    - namespace name (i.e. `default`)
    - service account name (i.e. `default`)


1. Get the kubernetes access token

    ```bash
    > kubectl exec nginx -- cat /var/run/secrets/tokens/oidc-token
    ```
    ```
    eyJhbGciOiJSUzI1NiIsImtpZCI6InNOLWFhN2JyX3VKdFptOTdMVmY2UXB3RkNIR1NCRkEtU0xoTmwyTVF1aFUifQ.eyJhdWQiOlsiYXBpOi8vQXp1cmVBRFRva2VuRXhjaGFuZ2UiXSwiZXhwIjoxNjczOTcxODc4LCJpYXQiOjE2NzM5NjQ2NzgsImlzcyI6Imh0dHBzOi8vazhzZmVkZXJhdGlvbi5ibG9iLmNvcmUud2luZG93cy5uZXQva2luZCIsImt1YmVybmV0ZXMuaW8iOnsibmFtZXNwYWNlIjoiZGVmYXVsdCIsInBvZCI6eyJuYW1lIjoibmdpbngiLCJ1aWQiOiI2ODRjNjcxMS1kYzMyLTQ1MzItOWQ4Ny0zMWM4YTMzYjNkZjAifSwic2VydmljZWFjY291bnQiOnsibmFtZSI6ImRlZmF1bHQiLCJ1aWQiOiIyNmZkZThiYi00Y2NkLTRkMzQtOGEwMy1mOThmNzQ1MzQ1MjQifX0sIm5iZiI6MTY3Mzk2NDY3OCwic3ViIjoic3lzdGVtOnNlcnZpY2VhY2NvdW50OmRlZmF1bHQ6ZGVmYXVsdCJ9.W8XCFO2rkldQRoyCduseUkQt7qlYtPZHDeSWoLeJ9Q9GlqY1HYIibpubwQZgSZ_UrVtPLO3aPHsyPDcbqTv8IsKAKBeBR6SvJMoLvxm982aolO_OsU8_5hgZQKegLjdGEkLpDbDln_wTLqyYHiKTBrgwhUoZpiu7LQfNgZRfXYyOzZ2YnE55oi10y1ejzc2nNC2xHFjeLHlZUmoBzpRkFQmtrphWrSFHEPmX0-4fE7Zv1bX7DisNgaDDpRAizhKO5Xrzk5PVr7XFcdCdCza63BX5H80aigbtCOdaofTN2mtOZvVuiRQuc5wDC_Lj0T-usTEYGVjxtzGji3xCCa34uw
    ```

      you might inspect the token as follows:

    ```bash
    > kubectl exec nginx -- cat /var/run/secrets/tokens/oidc-token | step crypto jwt inspect --insecure
    ```
    ```json
    {
      "header": {
        "alg": "RS256",
        "kid": "sN-aa7br_uJtZm97LVf6QpwFCHGSBFA-SLhNl2MQuhU"
      },
      "payload": {
        "aud": [
          "api://AzureADTokenExchange"
        ],
        "exp": 1673971878,
        "iat": 1673964678,
        "iss": "https://k8sfederation.blob.core.windows.net/kind",
        "kubernetes.io": {
          "namespace": "default",
          "pod": {
            "name": "nginx",
            "uid": "684c6711-dc32-4532-9d87-31c8a33b3df0"
          },
          "serviceaccount": {
            "name": "default",
            "uid": "26fde8bb-4ccd-4d34-8a03-f98f74534524"
          }
        },
        "nbf": 1673964678,
        "sub": "system:serviceaccount:default:default"
      },
      "signature": "W8XCFO2rkldQRoyCduseUkQt7qlYtPZHDeSWoLeJ9Q9GlqY1HYIibpubwQZgSZ_UrVtPLO3aPHsyPDcbqTv8IsKAKBeBR6SvJMoLvxm982aolO_OsU8_5hgZQKegLjdGEkLpDbDln_wTLqyYHiKTBrgwhUoZpiu7LQfNgZRfXYyOzZ2YnE55oi10y1ejzc2nNC2xHFjeLHlZUmoBzpRkFQmtrphWrSFHEPmX0-4fE7Zv1bX7DisNgaDDpRAizhKO5Xrzk5PVr7XFcdCdCza63BX5H80aigbtCOdaofTN2mtOZvVuiRQuc5wDC_Lj0T-usTEYGVjxtzGji3xCCa34uw"
    }
    ```

1. Use the Azure Active Directory access token for a target application (i.e. `1f249fd2-2681-44cb-bd14-28f899c557f3`) with the Client Credential Flow using the above kubernetes token

    ```bash
    > curl -s --request POST \
    --url https://login.microsoftonline.com/2862cc66-157f-445b-8c5d-f5a41f314800/oauth2/v2.0/token \
    --header 'content-type: application/x-www-form-urlencoded' \
    --header 'user-agent: vscode-restclient' \
    --data client_id=3ae4dafa-ec23-44c2-bdef-1cd220cacbac \
    --data client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
    --data client_assertion=eyJhbGciOiJSUzI1NiIsImtpZCI6InNOLWFhN2JyX3VKdFptOTdMVmY2UXB3RkNIR1NCRkEtU0xoTmwyTVF1aFUifQ.eyJhdWQiOlsiYXBpOi8vQXp1cmVBRFRva2VuRXhjaGFuZ2UiXSwiZXhwIjoxNjczOTcxODc4LCJpYXQiOjE2NzM5NjQ2NzgsImlzcyI6Imh0dHBzOi8vazhzZmVkZXJhdGlvbi5ibG9iLmNvcmUud2luZG93cy5uZXQva2luZCIsImt1YmVybmV0ZXMuaW8iOnsibmFtZXNwYWNlIjoiZGVmYXVsdCIsInBvZCI6eyJuYW1lIjoibmdpbngiLCJ1aWQiOiI2ODRjNjcxMS1kYzMyLTQ1MzItOWQ4Ny0zMWM4YTMzYjNkZjAifSwic2VydmljZWFjY291bnQiOnsibmFtZSI6ImRlZmF1bHQiLCJ1aWQiOiIyNmZkZThiYi00Y2NkLTRkMzQtOGEwMy1mOThmNzQ1MzQ1MjQifX0sIm5iZiI6MTY3Mzk2NDY3OCwic3ViIjoic3lzdGVtOnNlcnZpY2VhY2NvdW50OmRlZmF1bHQ6ZGVmYXVsdCJ9.W8XCFO2rkldQRoyCduseUkQt7qlYtPZHDeSWoLeJ9Q9GlqY1HYIibpubwQZgSZ_UrVtPLO3aPHsyPDcbqTv8IsKAKBeBR6SvJMoLvxm982aolO_OsU8_5hgZQKegLjdGEkLpDbDln_wTLqyYHiKTBrgwhUoZpiu7LQfNgZRfXYyOzZ2YnE55oi10y1ejzc2nNC2xHFjeLHlZUmoBzpRkFQmtrphWrSFHEPmX0-4fE7Zv1bX7DisNgaDDpRAizhKO5Xrzk5PVr7XFcdCdCza63BX5H80aigbtCOdaofTN2mtOZvVuiRQuc5wDC_Lj0T-usTEYGVjxtzGji3xCCa34uw \
    --data grant_type=client_credentials \
    --data scope=1f249fd2-2681-44cb-bd14-28f899c557f3/.default | jq -r .access_token | step crypto jwt inspect --insecure
    ```
    ```json
    {
      "header": {
        "alg": "RS256",
        "kid": "-KI3Q9nNR7bRofxmeZoXqbHZGew",
        "typ": "JWT",
        "x5t": "-KI3Q9nNR7bRofxmeZoXqbHZGew"
      },
      "payload": {
        "aud": "1f249fd2-2681-44cb-bd14-28f899c557f3",
        "iss": "https://sts.windows.net/2862cc66-157f-445b-8c5d-f5a41f314800/",
        "iat": 1673966930,
        "nbf": 1673966930,
        "exp": 1673970830,
        "aio": "E2ZgYGDM8TDp+NrCuHMhj3HK07oDAA==",
        "appid": "3ae4dafa-ec23-44c2-bdef-1cd220cacbac",
        "appidacr": "2",
        "idp": "https://sts.windows.net/2862cc66-157f-445b-8c5d-f5a41f314800/",
        "oid": "f27e69eb-e857-41bd-9b8b-2e576273c2a7",
        "rh": "0.AXoAZsxiKH8VW0SMXfWkHzFIANKfJB-BJstEvRQo-JnFV_N6AAA.",
        "roles": [
          "AppTwo.Access"
        ],
        "sub": "f27e69eb-e857-41bd-9b8b-2e576273c2a7",
        "tid": "2862cc66-157f-445b-8c5d-f5a41f314800",
        "uti": "NykLeDLG5UaWTxD-IRV9AA",
        "ver": "1.0"
      },
      "signature": "Ut4uC9GZ6XMuFhjOKJPG71yQjmlc-ETRble443fvM1yoJQXEPqe08ROHemUJZdpf_2C9gaxnUGg0gjs9gDMFAzBcy82oQvnnxP9ayc573oLQBlT903HhqI0mq10lkDwJTrZevJinPgOQKrr9cV8xv-GNAEASTnJWcFaJyvNcqzOv02o5Kr1YMYqBio0PBxHb7qqU5RNDqqCqA7vxFQ3LdM_JfTJWNqOr82mnHOIBuNoTZJqH4uZwVPFdSsi_Qtd6ZbYRJg1lnrGlEdy5x_mr6QBZ1n_Dm5BPAfWKX-QlcEiDqiHaxlcEAxlgjCnXgGnX7hriYTt4qzmhTsq0v50I7Q"
    }
    ```
