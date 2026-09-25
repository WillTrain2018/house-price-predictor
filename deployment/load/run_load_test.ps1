param(
    [string]$Endpoint = "http://localhost:30100/predict",
    [ValidateRange(1, 5000)]
    [int]$TargetRps = 500,
    [ValidateRange(1, 5000)]
    [int]$RampStepRps = 100,
    [ValidateRange(1, 3600)]
    [int]$PollingIntervalSeconds = 15,
    [ValidateRange(1, 3600)]
    [int]$HoldSeconds = 75,
    [ValidateRange(1, 3600)]
    [int]$CooldownPeriodSeconds = 75,
    [ValidateRange(1, 3600)]
    [int]$PrometheusWindowSeconds = 60,
    [ValidateRange(1, 1000)]
    [int]$MaxConcurrency = 128,
    [ValidateRange(1, 300)]
    [int]$RequestTimeoutSeconds = 5,
    [ValidateRange(1, 60000)]
    [int]$LatencyThresholdMs = 98
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http
[System.Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max(
    [System.Net.ServicePointManager]::DefaultConnectionLimit,
    $MaxConcurrency
)

$templatePath = Join-Path $PSScriptRoot "predict.json"
if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "Request template not found: $templatePath"
}

$baseRequest = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json
$requiredFields = @("sqft", "bedrooms", "bathrooms", "year_built", "condition", "location")
foreach ($field in $requiredFields) {
    if ($null -eq $baseRequest.PSObject.Properties[$field]) {
        throw "The request template is missing required field '$field'."
    }
}

$workerScript = {
    param($templateJson, $endpoint, $stageRps, $workerCount, $workerIndex, $stageSeconds, $requestTimeoutSeconds, $latencyThresholdMs)

    $template = ConvertFrom-Json -InputObject $templateJson

    $random = [System.Random]::new([Guid]::NewGuid().GetHashCode())
    $conditions = @("Fair", "Good", "Excellent")
    $locations = @("Urban", "Suburban", "Rural")
    $latencies = [System.Collections.Generic.List[double]]::new()
    $errorSamples = [System.Collections.Generic.List[string]]::new()
    $successCount = 0
    $failureCount = 0
    $timeoutCount = 0
    $overThresholdCount = 0
    $requestIntervalMs = 1000.0 * $workerCount / $stageRps
    $initialDelayMs = $requestIntervalMs * $workerIndex / $workerCount
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds($requestTimeoutSeconds)
    $stageTimer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        if ($initialDelayMs -gt 1) {
            Start-Sleep -Milliseconds ([int]$initialDelayMs)
        }
        while ($stageTimer.Elapsed.TotalSeconds -lt $stageSeconds) {
            $requestTimer = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $payload = @{}
                foreach ($property in $template.PSObject.Properties) {
                    $payload[$property.Name] = $property.Value
                }

                $payload["sqft"] = $random.Next(700, 5001)
                $payload["bedrooms"] = $random.Next(1, 7)
                $payload["bathrooms"] = $random.Next(2, 10) / 2.0
                $payload["year_built"] = $random.Next(1950, 2024)
                $payload["condition"] = $conditions[$random.Next(0, $conditions.Length)]
                $payload["location"] = $locations[$random.Next(0, $locations.Length)]

                $json = ConvertTo-Json -InputObject $payload -Compress
                $content = [System.Net.Http.StringContent]::new(
                    $json,
                    [System.Text.Encoding]::UTF8,
                    "application/json"
                )
                try {
                    $response = $client.PostAsync($endpoint, $content).GetAwaiter().GetResult()
                    try {
                        $requestTimer.Stop()
                        $latency = $requestTimer.Elapsed.TotalMilliseconds
                        $latencies.Add($latency)
                        if ($latency -gt $latencyThresholdMs) {
                            $overThresholdCount++
                        }
                        if ($response.IsSuccessStatusCode) {
                            $successCount++
                        }
                        else {
                            $failureCount++
                            if ($errorSamples.Count -lt 3) {
                                $errorSamples.Add("HTTP $([int]$response.StatusCode) $($response.ReasonPhrase)")
                            }
                        }
                    }
                    finally {
                        $response.Dispose()
                    }
                }
                finally {
                    $content.Dispose()
                }
            }
            catch {
                $requestTimer.Stop()
                $latencies.Add($requestTimer.Elapsed.TotalMilliseconds)
                $failureCount++
                $exception = $_.Exception.GetBaseException()
                if ($exception -is [System.Threading.Tasks.TaskCanceledException] -or
                    $exception -is [System.OperationCanceledException]) {
                    $timeoutCount++
                }
                if ($errorSamples.Count -lt 3) {
                    $errorSamples.Add($exception.Message)
                }
            }

            $remainingMs = $requestIntervalMs - $requestTimer.Elapsed.TotalMilliseconds
            if ($remainingMs -gt 1) {
                Start-Sleep -Milliseconds ([int]$remainingMs)
            }
        }
    }
    finally {
        $stageTimer.Stop()
        $client.Dispose()
    }

    [PSCustomObject]@{
        Success = $successCount
        Failed = $failureCount
        TimedOut = $timeoutCount
        OverLatencyThreshold = $overThresholdCount
        LatenciesMs = $latencies.ToArray()
        ErrorSamples = $errorSamples.ToArray()
    }
}

function Invoke-LoadWorkers {
    param(
        [scriptblock]$ScriptBlock,
        [int]$WorkerCount,
        [string]$TemplateJson,
        [string]$RequestEndpoint,
        [int]$RequestRate,
        [int]$DurationSeconds,
        [int]$TimeoutSeconds,
        [int]$ThresholdMs
    )

    $pool = [RunspaceFactory]::CreateRunspacePool(1, $WorkerCount)
    $pool.Open()
    $pending = [System.Collections.Generic.List[object]]::new()
    $results = [System.Collections.Generic.List[object]]::new()

    try {
        for ($worker = 0; $worker -lt $WorkerCount; $worker++) {
            $instance = [PowerShell]::Create()
            $instance.RunspacePool = $pool
            [void]$instance.AddScript($ScriptBlock.ToString())
            [void]$instance.AddArgument($TemplateJson)
            [void]$instance.AddArgument($RequestEndpoint)
            [void]$instance.AddArgument($RequestRate)
            [void]$instance.AddArgument($WorkerCount)
            [void]$instance.AddArgument($worker)
            [void]$instance.AddArgument($DurationSeconds)
            [void]$instance.AddArgument($TimeoutSeconds)
            [void]$instance.AddArgument($ThresholdMs)
            $handle = $instance.BeginInvoke()
            $pending.Add([PSCustomObject]@{ Instance = $instance; Handle = $handle })
        }

        foreach ($job in $pending) {
            $workerOutput = $job.Instance.EndInvoke($job.Handle)
            foreach ($result in $workerOutput) {
                $results.Add($result)
            }
        }

        return $results.ToArray()
    }
    finally {
        foreach ($job in $pending) {
            $job.Instance.Dispose()
        }
        $pool.Close()
        $pool.Dispose()
    }
}

$templateJson = ConvertTo-Json -InputObject $baseRequest -Compress -Depth 10

$endpointUri = [Uri]$Endpoint
$healthUri = [UriBuilder]::new($endpointUri)
$healthUri.Path = $endpointUri.AbsolutePath -replace "/predict/?$", "/health"
$preflightClient = [System.Net.Http.HttpClient]::new()
$preflightClient.Timeout = [TimeSpan]::FromSeconds(10)
try {
    $healthResponse = $preflightClient.GetAsync($healthUri.Uri).GetAwaiter().GetResult()
    try {
        if (-not $healthResponse.IsSuccessStatusCode) {
            throw "Health endpoint returned HTTP $([int]$healthResponse.StatusCode)."
        }
    }
    finally {
        $healthResponse.Dispose()
    }

    $preflightContent = [System.Net.Http.StringContent]::new(
        $templateJson,
        [System.Text.Encoding]::UTF8,
        "application/json"
    )
    try {
        $predictionResponse = $preflightClient.PostAsync($Endpoint, $preflightContent).GetAwaiter().GetResult()
        try {
            if (-not $predictionResponse.IsSuccessStatusCode) {
                throw "Prediction preflight returned HTTP $([int]$predictionResponse.StatusCode)."
            }
        }
        finally {
            $predictionResponse.Dispose()
        }
    }
    finally {
        $preflightContent.Dispose()
    }
}
catch {
    throw "API preflight failed; no load was sent. Check that '$Endpoint' is reachable and accepts predict.json. $($_.Exception.GetBaseException().Message)"
}
finally {
    $preflightClient.Dispose()
}

$rampRates = [System.Collections.Generic.List[int]]::new()
for ($rate = $RampStepRps; $rate -lt $TargetRps; $rate += $RampStepRps) {
    $rampRates.Add($rate)
}
if ($rampRates.Count -eq 0 -or $rampRates[$rampRates.Count - 1] -ne $TargetRps) {
    $rampRates.Add($TargetRps)
}

$stageSummaries = [System.Collections.Generic.List[object]]::new()
$totalSuccess = 0
$totalFailed = 0
$totalLoadSeconds = 0
$allLatencies = [System.Collections.Generic.List[double]]::new()

Write-Host "Endpoint: $Endpoint"
Write-Host "Request-rate target: $TargetRps requests/second; max concurrency: $MaxConcurrency"
Write-Host "Per-request timeout: $RequestTimeoutSeconds seconds; .NET connection limit: $([System.Net.ServicePointManager]::DefaultConnectionLimit)"
Write-Host "Ramp: $($rampRates -join ' -> ') RPS, holding each stage for $PollingIntervalSeconds seconds"
Write-Host "Final load hold: $HoldSeconds seconds; idle observation: $($PrometheusWindowSeconds + $CooldownPeriodSeconds) seconds"
Write-Host "Latency threshold: p99 $LatencyThresholdMs ms (KEDA threshold: 0.098 seconds)"
Write-Host ""

foreach ($stageRps in $rampRates) {
    $stageSeconds = $PollingIntervalSeconds
    $workerCount = [Math]::Min($stageRps, $MaxConcurrency)
    $stageWatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "Load stage: target $stageRps RPS for $stageSeconds seconds ($workerCount workers)"

    $workerResults = Invoke-LoadWorkers -ScriptBlock $workerScript -WorkerCount $workerCount -TemplateJson $templateJson -RequestEndpoint $Endpoint -RequestRate $stageRps -DurationSeconds $stageSeconds -TimeoutSeconds $RequestTimeoutSeconds -ThresholdMs $LatencyThresholdMs
    $stageWatch.Stop()

    $stageSuccess = 0
    $stageFailed = 0
    $stageTimeouts = 0
    $stageOverThreshold = 0
    $stageLatencies = [System.Collections.Generic.List[double]]::new()
    $stageErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($result in $workerResults) {
        $stageSuccess += $result.Success
        $stageFailed += $result.Failed
        $stageTimeouts += $result.TimedOut
        $stageOverThreshold += $result.OverLatencyThreshold
        foreach ($latency in $result.LatenciesMs) {
            $stageLatencies.Add($latency)
            $allLatencies.Add($latency)
        }
        foreach ($sample in $result.ErrorSamples) {
            if ($stageErrors.Count -lt 3) {
                $stageErrors.Add($sample)
            }
        }
    }

    $stageRequests = $stageSuccess + $stageFailed
    $actualRps = if ($stageWatch.Elapsed.TotalSeconds -gt 0) {
        [Math]::Round($stageRequests / $stageWatch.Elapsed.TotalSeconds, 2)
    } else { 0 }
    $stageP99 = $null
    if ($stageLatencies.Count -gt 0) {
        $sortedStageLatencies = @($stageLatencies | Sort-Object)
        $p99Index = [Math]::Max(0, [Math]::Ceiling(0.99 * $sortedStageLatencies.Count) - 1)
        $stageP99 = [Math]::Round($sortedStageLatencies[$p99Index], 2)
    }

    $stageSummaries.Add([PSCustomObject]@{
        TargetRps = $stageRps
        DurationSeconds = [Math]::Round($stageWatch.Elapsed.TotalSeconds, 2)
        Workers = $workerCount
        Requests = $stageRequests
        Successful = $stageSuccess
        Failed = $stageFailed
        TimedOut = $stageTimeouts
        AchievedRps = $actualRps
        P99LatencyMs = $stageP99
        RequestsOver98Ms = $stageOverThreshold
    })
    $totalSuccess += $stageSuccess
    $totalFailed += $stageFailed
    $totalLoadSeconds += $stageWatch.Elapsed.TotalSeconds

    Write-Host "  Attempts: $stageRequests; succeeded: $stageSuccess; failed: $stageFailed ($stageTimeouts timed out); achieved: $actualRps RPS; p99: $stageP99 ms"
    foreach ($sample in $stageErrors) {
        Write-Host "  Error sample: $sample"
    }
}

if ($HoldSeconds -gt 0) {
    $stageRps = $TargetRps
    $stageSeconds = $HoldSeconds
    $workerCount = [Math]::Min($stageRps, $MaxConcurrency)
    $stageWatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "Sustain stage: target $stageRps RPS for $stageSeconds seconds ($workerCount workers)"

    $workerResults = Invoke-LoadWorkers -ScriptBlock $workerScript -WorkerCount $workerCount -TemplateJson $templateJson -RequestEndpoint $Endpoint -RequestRate $stageRps -DurationSeconds $stageSeconds -TimeoutSeconds $RequestTimeoutSeconds -ThresholdMs $LatencyThresholdMs
    $stageWatch.Stop()

    $stageSuccess = 0
    $stageFailed = 0
    $stageTimeouts = 0
    $stageOverThreshold = 0
    $stageLatencies = [System.Collections.Generic.List[double]]::new()
    $stageErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($result in $workerResults) {
        $stageSuccess += $result.Success
        $stageFailed += $result.Failed
        $stageTimeouts += $result.TimedOut
        $stageOverThreshold += $result.OverLatencyThreshold
        foreach ($latency in $result.LatenciesMs) {
            $stageLatencies.Add($latency)
            $allLatencies.Add($latency)
        }
        foreach ($sample in $result.ErrorSamples) {
            if ($stageErrors.Count -lt 3) {
                $stageErrors.Add($sample)
            }
        }
    }

    $stageRequests = $stageSuccess + $stageFailed
    $actualRps = if ($stageWatch.Elapsed.TotalSeconds -gt 0) {
        [Math]::Round($stageRequests / $stageWatch.Elapsed.TotalSeconds, 2)
    } else { 0 }
    $stageP99 = $null
    if ($stageLatencies.Count -gt 0) {
        $sortedStageLatencies = @($stageLatencies | Sort-Object)
        $p99Index = [Math]::Max(0, [Math]::Ceiling(0.99 * $sortedStageLatencies.Count) - 1)
        $stageP99 = [Math]::Round($sortedStageLatencies[$p99Index], 2)
    }

    $stageSummaries.Add([PSCustomObject]@{
        TargetRps = $stageRps
        DurationSeconds = [Math]::Round($stageWatch.Elapsed.TotalSeconds, 2)
        Workers = $workerCount
        Requests = $stageRequests
        Successful = $stageSuccess
        Failed = $stageFailed
        TimedOut = $stageTimeouts
        AchievedRps = $actualRps
        P99LatencyMs = $stageP99
        RequestsOver98Ms = $stageOverThreshold
    })
    $totalSuccess += $stageSuccess
    $totalFailed += $stageFailed
    $totalLoadSeconds += $stageWatch.Elapsed.TotalSeconds

    Write-Host "  Attempts: $stageRequests; succeeded: $stageSuccess; failed: $stageFailed ($stageTimeouts timed out); achieved: $actualRps RPS; p99: $stageP99 ms"
    foreach ($sample in $stageErrors) {
        Write-Host "  Error sample: $sample"
    }
}

$overallP99 = $null
if ($allLatencies.Count -gt 0) {
    $sortedLatencies = @($allLatencies | Sort-Object)
    $overallP99Index = [Math]::Max(0, [Math]::Ceiling(0.99 * $sortedLatencies.Count) - 1)
    $overallP99 = [Math]::Round($sortedLatencies[$overallP99Index], 2)
}
$overallRps = if ($totalLoadSeconds -gt 0) {
    [Math]::Round(($totalSuccess + $totalFailed) / $totalLoadSeconds, 2)
} else { 0 }

$resultsPath = Join-Path $PSScriptRoot ("load-test-results-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$stageSummaries | Export-Csv -LiteralPath $resultsPath -NoTypeInformation -Encoding utf8

Write-Host ""
Write-Host "Load summary: requests $($totalSuccess + $totalFailed); succeeded $totalSuccess; failed $totalFailed; achieved $overallRps RPS; overall p99 $overallP99 ms"
Write-Host "Stages written to: $resultsPath"
Write-Host ""
Write-Host "Load is complete. Observe the deployment during the next $($PrometheusWindowSeconds + $CooldownPeriodSeconds) seconds for KEDA scale-down; the Prometheus query uses a $PrometheusWindowSeconds-second rate window."
Write-Host ""
$stageSummaries | Format-Table -AutoSize

if ($CooldownPeriodSeconds -gt 0) {
    Write-Host "Idle observation started; no requests will be sent for $($PrometheusWindowSeconds + $CooldownPeriodSeconds) seconds."
    Start-Sleep -Seconds ($PrometheusWindowSeconds + $CooldownPeriodSeconds)
    Write-Host "Idle observation complete."
}