# Public approved evaluation-media HEAD only, no download or TLS bypass.
$ErrorActionPreference = 'Stop'
$uri = 'https://software-static.download.prss.microsoft.com/dbazure/998969d5-f34g-4e03-ac9d-1f9786c66749/26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso'
$result = @{ computer = $env:COMPUTERNAME; atUtc = (Get-Date).ToUniversalTime().ToString('o'); host = ([uri]$uri).DnsSafeHost; method = 'HEAD'; mediaBytesDownloaded = 0; httpStatus = $null }
$request = [Net.HttpWebRequest]::Create($uri)
$request.Method = 'HEAD'
$request.AllowAutoRedirect = $false
$request.UseDefaultCredentials = $false
$request.Timeout = 20000
try { $response = $request.GetResponse(); try { $result.httpStatus = [int]$response.StatusCode; $result.bytes = $response.ContentLength; $result.etag = $response.Headers['ETag'] } finally { $response.Close() } }
catch [Net.WebException] { $result.error = $_.Exception.Status.ToString(); if ($_.Exception.Response) { $result.httpStatus = [int]$_.Exception.Response.StatusCode; $_.Exception.Response.Close() } }
$result | ConvertTo-Json -Compress
