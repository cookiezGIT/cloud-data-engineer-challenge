SHELL := powershell.exe
.SHELLFLAGS := -NoProfile -ExecutionPolicy Bypass -Command

PYVER := 3.10
IMG   := public.ecr.aws/lambda/python:$(PYVER)

clean:
	$${P}=(Get-Location).Path; Remove-Item -Recurse -Force 'build' -ErrorAction Ignore; Write-Output 'cleaned'

build-linux-api:
	$${P}=(Get-Location).Path; Remove-Item -Recurse -Force 'build/api' -ErrorAction Ignore; New-Item -ItemType Directory -Force 'build/api/package' | Out-Null; docker run --rm --entrypoint /bin/sh -v "$$($$P):/var/task" -w /var/task $(IMG) -c "pip install -r lambda/api/requirements.txt -t build/api/package"; Copy-Item -Recurse -Force 'lambda/api/*' 'build/api/package/'; if (Test-Path 'build/api.zip') { Remove-Item 'build/api.zip' }; Compress-Archive -Path 'build/api/package/*' -DestinationPath 'build/api.zip'; Write-Output 'OK: build/api.zip'

build-linux-ingest:
	$${P}=(Get-Location).Path; Remove-Item -Recurse -Force 'build/ingest' -ErrorAction Ignore; New-Item -ItemType Directory -Force 'build/ingest/package' | Out-Null; docker run --rm --entrypoint /bin/sh -v "$$($$P):/var/task" -w /var/task $(IMG) -c "pip install -r lambda/ingest/requirements.txt -t build/ingest/package"; Copy-Item -Recurse -Force 'lambda/ingest/*' 'build/ingest/package/'; if (Test-Path 'build/ingest.zip') { Remove-Item 'build/ingest.zip' }; Compress-Archive -Path 'build/ingest/package/*' -DestinationPath 'build/ingest.zip'; Write-Output 'OK: build/ingest.zip'

build-linux-all: build-linux-api build-linux-ingest
	powershell -NoProfile -ExecutionPolicy Bypass -Command "Write-Output 'All lambda zips ready under build/'"

build-linux-admin:
	$${P}=(Get-Location).Path; 
	Remove-Item -Recurse -Force 'build/admin_sql' -ErrorAction Ignore; 
	New-Item -ItemType Directory -Force 'build/admin_sql/package' | Out-Null; 
	docker run --rm --entrypoint /bin/sh -v "$$($$P):/var/task" -w /var/task public.ecr.aws/lambda/python:3.10 -c "pip install -r lambda/admin_sql/requirements.txt -t build/admin_sql/package"; 
	Copy-Item -Recurse -Force 'lambda/admin_sql/*' 'build/admin_sql/package/'; 
	if (Test-Path 'build/admin_sql.zip') { Remove-Item 'build/admin_sql.zip' }; 
	Compress-Archive -Path 'build/admin_sql/package/*' -DestinationPath 'build/admin_sql.zip'; 
	Write-Output 'OK: build/admin_sql.zip'
