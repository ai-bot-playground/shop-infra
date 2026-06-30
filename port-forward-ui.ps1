# Port-forward the three "localhost UI" services from kind-preprod.
# Run in a dedicated terminal — Ctrl+C stops all forwards.
#
# After running this script:
#   shop-ui            → http://localhost:3001
#   shop-token-metrics → http://localhost:8088
#   shop-qa-ui         → run locally (see below)
#
# shop-qa-ui is NOT deployed in the cluster. Start it separately:
#   cd ..\shop-qa-ui ; .\.venv\Scripts\activate ; streamlit run app.py --server.port 8501
# ---------------------------------------------------------------------------

$context = "kind-preprod"
$namespace = "shop"

Write-Host "Starting port-forwards (context=$context, namespace=$namespace) ..." -ForegroundColor Cyan
Write-Host "  shop-ui            -> http://localhost:3001" -ForegroundColor Green
Write-Host "  shop-token-metrics -> http://localhost:8088" -ForegroundColor Green
Write-Host ""
Write-Host "Press Ctrl+C to stop all." -ForegroundColor Yellow
Write-Host ""

$jobs = @()

$jobs += Start-Job -Name "pf-shop-ui" -ScriptBlock {
    kubectl --context $using:context -n $using:namespace port-forward svc/shop-ui 3001:80
}

$jobs += Start-Job -Name "pf-shop-token-metrics" -ScriptBlock {
    kubectl --context $using:context -n $using:namespace port-forward svc/shop-token-metrics 8088:8080
}

try {
    # Stream output from both jobs until Ctrl+C.
    while ($true) {
        foreach ($j in $jobs) {
            Receive-Job $j -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
    }
} finally {
    Write-Host "`nStopping port-forwards..." -ForegroundColor Yellow
    $jobs | Stop-Job -PassThru | Remove-Job -Force
}
