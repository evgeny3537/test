# Загрузка необходимых сборок и модулей
Add-Type -Path "C:\Users\evgeny\Pictures\StitchEngine.DLL"
Import-Module Microsoft.PowerShell.Management
Import-Module Microsoft.PowerShell.Utility
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Set-ExecutionPolicy Unrestricted -Scope Process

# Задайте пути:
$iceDllPath    = "C:\Users\evgeny\Pictures\StitchEngine.DLL"
$inputFolder   = "C:\Users\evgeny\Pictures\фото"         # Папка с исходными JPG
$outputFolder  = "C:\Users\evgeny\Pictures"               # Папка для сохранения итоговых изображений

function Start-StitchingProcess {
    # Загрузка сборки StitchEngine.DLL
    Add-Type -Path $iceDllPath

    # Создание объекта AutoResetEvent для синхронизации
    $taskCompleted = New-Object System.Threading.AutoResetEvent($false)

    # Создание экземпляра StitchEngineWrapper
    $stitch = New-Object Microsoft.Research.ICE.Stitching.StitchEngineWrapper
    if (-not $stitch) {
        Write-Host "Не удалось создать экземпляр StitchEngineWrapper."
        return
    }

    # Подписка на событие ProgressChanged
    $progressHandler = Register-ObjectEvent -InputObject $stitch -EventName ProgressChanged -Action {
        Write-Host -NoNewline "."
    }

    # Подписка на событие TaskCompleted
    $completedHandler = Register-ObjectEvent -InputObject $stitch -EventName TaskCompleted -Action {
        Write-Host "Задача завершена."
        $taskCompleted.Set() | Out-Null
    }

    # Получаем список всех JPG-файлов из заданной папки
    $imageFiles = Get-ChildItem -Path $inputFolder -Filter *.jpg
    if ($imageFiles.Count -eq 0) {
        Write-Host "Файлы изображений не найдены в папке $inputFolder. Ожидание появления новых файлов..."
        return
    }

    # Создание объекта проекта для сшивания
    $projectInfo = New-Object Microsoft.Research.ICE.Stitching.StitchProjectInfo
    foreach ($file in $imageFiles) {
        $imgInfo = New-Object Microsoft.Research.ICE.Stitching.ImageInfo($file.FullName, $null)
        $projectInfo.SourceImages.Add($imgInfo) | Out-Null
    }

    # Инициализация stitch engine
    $result = $stitch.InitializeFromProjectInfo($projectInfo)
    if (-not $result -or $stitch.HasLastError) {
        Write-Host "Инициализация не удалась."
        if ($stitch.HasLastError) {
            $errorHex = "{0:x8}" -f $stitch.LastError
            Write-Host "Ошибка 0x${errorHex}: $($stitch.LastErrorMessage)"
        }
        Unregister-Event -SourceIdentifier $progressHandler.Name
        Unregister-Event -SourceIdentifier $completedHandler.Name
        $stitch.Dispose()
        return
    }
    Write-Host "Инициализация прошла успешно."

    # Время ожидания завершения задачи изменено на 3 секунду
    $timeout = [System.TimeSpan]::FromSeconds(3)

    # Этап 1: Выравнивание
    Write-Host "Начало выравнивания..."
    $alignResult = $stitch.StartAligning()
    Write-Host $alignResult
    Write-Host "Ожидание завершения задачи..."
    $taskCompleted.WaitOne($timeout) | Out-Null
    if ($stitch.AlignedCount -lt 2 -or $stitch.HasLastError) {
        Write-Host "Ошибка при выравнивании."
        $errorHex = "{0:x8}" -f $stitch.LastError
        Write-Host "Ошибка 0x${errorHex}: $($stitch.LastErrorMessage)"
        Unregister-Event -SourceIdentifier $progressHandler.Name
        Unregister-Event -SourceIdentifier $completedHandler.Name
        $stitch.Dispose()
        return
    }
    Write-Host "Выравнивание прошло успешно."

    # Этап 2: Композитинг
    Write-Host "Начало композиции..."
    $compositeResult = $stitch.StartCompositing()
    Write-Host $compositeResult
    Write-Host "Ожидание завершения задачи..."
    $taskCompleted.WaitOne($timeout) | Out-Null
    if ($stitch.HasLastError) {
        Write-Host "Ошибка при композиции."
        $errorHex = "{0:x8}" -f $stitch.LastError
        Write-Host "Ошибка 0x${errorHex}: $($stitch.LastErrorMessage)"
        Unregister-Event -SourceIdentifier $progressHandler.Name
        Unregister-Event -SourceIdentifier $completedHandler.Name
        $stitch.Dispose()
        return
    }
    Write-Host "Композиция прошла успешно."

    # Этап 3: Проецирование
    Write-Host "Начало проекции..."
    $projectResult = $stitch.StartProjecting()
    Write-Host $projectResult
    Write-Host "Ожидание завершения задачи..."
    $taskCompleted.WaitOne($timeout) | Out-Null
    if ($stitch.HasLastError) {
        Write-Host "Ошибка при проекции."
        $errorHex = "{0:x8}" -f $stitch.LastError
        Write-Host "Ошибка 0x${errorHex}: $($stitch.LastErrorMessage)"
        Unregister-Event -SourceIdentifier $progressHandler.Name
        Unregister-Event -SourceIdentifier $completedHandler.Name
        $stitch.Dispose()
        return
    }
    Write-Host "Проекция прошла успешно."

    # Ожидание инициализации ResetCropRect (увеличено до 10 секунд)
    Write-Host "Ожидание инициализации ResetCropRect..."
    $maxWait = 10
    $wait = 0
    while (($stitch.ResetCropRect -eq $null) -and ($wait -lt $maxWait)) {
        Start-Sleep -Seconds 1
        $wait++
    }

    if ($stitch.ResetCropRect -ne $null) {
        $cropRect = $stitch.ResetCropRect
        Write-Host ".ResetCropRect успешно инициализирован."
    } else {
        Write-Host "ResetCropRect не инициализирован за $maxWait секунд. Используем значение по умолчанию."
        Add-Type -AssemblyName WindowsBase
        $cropRect = [System.Windows.Int32Rect]::Empty
    }

    # Дополнительная задержка для полной инициализации внутренних объектов перед экспортом
    Write-Host "Пауза перед экспортом для завершения инициализации внутренних объектов..."
    Start-Sleep -Seconds 1

    # Этап 4: Экспорт
    Write-Host "Начало экспорта..."
    $exportFormat  = [Microsoft.Research.ICE.Stitching.ExportFormat]::JPEG
    $outputOptions = New-Object Microsoft.Research.ICE.Stitching.OutputOptions($exportFormat, 75, $true, $false, $false)
    $outputFileName = "final" + "{0:D4}" -f ($global:taskCounter) + ".jpg"
    $outputPath     = Join-Path -Path $outputFolder -ChildPath $outputFileName

    if ($cropRect -eq $null) {
        Write-Host "Ошибка: cropRect равен null. Экспорт невозможен."
        Unregister-Event -SourceIdentifier $progressHandler.Name
        Unregister-Event -SourceIdentifier $completedHandler.Name
        $stitch.Dispose()
        return
    }

    Write-Host "Проверка параметров экспорта:"
    Write-Host "OutputPath: $outputPath"
    Write-Host "CropRect: $($cropRect.ToString())"
    Write-Host "OutputOptions: $($outputOptions.ToString())"

    # Изолированный вызов экспорта через runspace с STA
    $staRunspace = [runspacefactory]::CreateRunspace()
    $staRunspace.ApartmentState = "STA"
    $staRunspace.ThreadOptions = "ReuseThread"
    $staRunspace.Open()

    $pipeline = $staRunspace.CreatePipeline()

    $exportScript = {
        param($stitch, $outputPath, $cropRect, $options)
        try {
            $stitch.StartExporting($outputPath, $cropRect, 1, $options, $false)
            return "Экспорт завершен: $outputPath"
        } catch {
            return "Ошибка при экспорте в runspace: $_"
        }
    }
    $pipeline.Commands.AddScript($exportScript) | Out-Null
    $pipeline.Commands[0].Parameters.Add("stitch", $stitch)
    $pipeline.Commands[0].Parameters.Add("outputPath", $outputPath)
    $pipeline.Commands[0].Parameters.Add("cropRect", $cropRect)
    $pipeline.Commands[0].Parameters.Add("options", $outputOptions)

    $results = $pipeline.Invoke()
    $staRunspace.Close()

    foreach ($line in $results) {
        Write-Host $line
    }

    $global:taskCounter++
    Write-Host "Удаление файлов в папке $inputFolder..."
    Get-ChildItem -Path $inputFolder -Filter *.jpg | Remove-Item -Force

    Unregister-Event -SourceIdentifier $progressHandler.Name
    Unregister-Event -SourceIdentifier $completedHandler.Name
    if ($stitch -and $stitch.Dispose) { $stitch.Dispose() }
    Write-Host "Работа завершена."
}

# Инициализация счётчика для файлов
$global:taskCounter = 1

# Основной цикл ожидания появления новых файлов
while ($true) {
    Start-StitchingProcess
    Write-Host "Ожидание новых файлов в папке $inputFolder..."
    while (-not (Get-ChildItem -Path $inputFolder -Filter *.jpg).Count) {
        Start-Sleep -Seconds 5
    }
}
