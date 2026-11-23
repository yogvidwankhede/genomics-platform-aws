from gp_api.lambda_handler import handler


def test_health(client):
    assert client.get("/health").json()["status"] == "ok"


def test_list_runs_newest_first(client):
    body = client.get("/runs").json()
    assert body["count"] == 3
    assert [r["run_id"] for r in body["runs"]] == ["run-pending", "run-new", "run-old"]


def test_list_runs_by_status_uses_index(client):
    body = client.get("/runs", params={"status": "succeeded"}).json()
    assert [r["run_id"] for r in body["runs"]] == ["run-old"]
    assert body["runs"][0]["duration_seconds"] == 120.5
    assert body["runs"][0]["samples"]["HG001"]["snp_f1"] == 0.998116


def test_list_runs_rejects_unknown_status(client):
    assert client.get("/runs", params={"status": "bogus"}).status_code == 422


def test_get_run_404(client):
    assert client.get("/runs/does-not-exist").status_code == 404


def test_run_id_is_validated(client):
    assert client.get("/runs/NOT_VALID").status_code == 422


def test_qc(client):
    body = client.get("/runs/run-old/qc").json()
    assert body == [
        {
            "sample": "HG001",
            "reads_before_filtering": 500604,
            "reads_after_filtering": 487066,
            "q30_rate_after_filtering": 0.897511,
            "percent_duplication": 0.111089,
        }
    ]


def test_variants_include_benchmark(client):
    [sample] = client.get("/runs/run-old/variants").json()
    assert sample["snps"] == 2815
    assert sample["benchmark"]["SNP"]["f1"] == 0.998116
    assert sample["benchmark"]["INDEL"]["truth_total"] == 405


def test_results_not_ready_is_409(client):
    assert client.get("/runs/run-pending/variants").status_code == 409


def test_lambda_function_url_event(client):
    event = {
        "version": "2.0",
        "routeKey": "$default",
        "rawPath": "/health",
        "rawQueryString": "",
        "headers": {"host": "x.lambda-url.us-east-1.on.aws"},
        "requestContext": {
            "http": {"method": "GET", "path": "/health", "sourceIp": "1.2.3.4", "protocol": "HTTP/1.1"},
            "domainName": "x.lambda-url.us-east-1.on.aws",
            "stage": "$default",
            "requestId": "r",
            "accountId": "123",
        },
        "isBase64Encoded": False,
    }
    resp = handler(event, None)
    assert resp["statusCode"] == 200
