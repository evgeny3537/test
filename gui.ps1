Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path "C:\Users\evgeny\Pictures\StitchEngine.DLL"
Import-Module Microsoft.PowerShell.Management
Import-Module Microsoft.PowerShell.Utility
Set-ExecutionPolicy Unrestricted -Scope Process
# Пути к DLL и папкам
$iceDllPath    = "C:\Users\evgeny\Pictures\StitchEngine.DLL"
$inputFolder   = "C:\Users\evgeny\Pictures\фото"         # Папка с исходными JPG
$outputFolder  = "C:\Users\evgeny\Pictures"               # Папка для сохранения итоговых изображений

# Создаем окно и элементы управления
$form = New-Object System.Windows.Forms.Form
$form.Text = "Stitching Process"
$form.Size = New-Object System.Drawing.Size(400, 250)

# Текстовое поле для вывода сообщений
$outputBox = New-Object System.Windows.Forms.TextBox
$outputBox.Multiline = $true
$outputBox.Size = New-Object System.Drawing.Size(350, 120)
$outputBox.Location = New-Object System.Drawing.Point(20, 20)
$form.Controls.Add($outputBox)

# Кнопка для начала процесса
$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "Начать Сшивание"
$startButton.Size = New-Object System.Drawing.Size(120, 40)
$startButton.Location = New-Object System.Drawing.Point(140, 150)
$form.Controls.Add($startButton)

# Функция для обновления вывода на экран
function Update-Output {
    param ($message)
    $outputBox.AppendText("$message`r`n")
    $outputBox.SelectionStart = $outputBox.Text.Length
    $outputBox.ScrollToCaret()
}

# Основная функция сшивания
function Start-StitchingProcess {
    Add-Type -Path $iceDllPath
    $taskCompleted = New-Object System.Threading.AutoResetEvent($false)
    $stitch = New-Object Microsoft.Research.ICE.Stitching.StitchEngineWrapper

    if (-not $stitch) {
        Update-Output "Не удалось создать экземпляр StitchEngineWrapper."
        return
    }

    $progressHandler = Register-ObjectEvent -InputObject $stitch -EventName ProgressChanged -Action {
        Update-Output "..."
    }

    $completedHandler = Register-ObjectEvent -InputObject $stitch -EventName TaskCompleted -Action {
        Update-Output "Задача завершена."
        $taskCompleted.Set() | Out-Null
    }

    $imageFiles = Get-ChildItem -Path $inputFolder -Filter *.jpg
    if ($imageFiles.Count -eq 0) {
        Update-Output "Файлы изображений не найдены в папке $inputFolder."
        return
    }

    $projectInfo = New-Object Microsoft.Research.ICE.Stitching.StitchProjectInfo
    foreach ($file in $imageFiles) {
        $imgInfo = New-Object Microsoft.Research.ICE.Stitching.ImageInfo($file.FullName, $null)
        $projectInfo.SourceImages.Add($imgInfo) | Out-Null
    }

    $result = $stitch.InitializeFromProjectInfo($projectInfo)
    if (-not $result -or $stitch.HasLastError) {
        Update-Output "Инициализация не удалась."
        if ($stitch.HasLastError) {
            $errorHex = "{0:x8}" -f $stitch.LastError
            Update-Output "Ошибка 0x${errorHex}: $($stitch.LastErrorMessage)"
        }
        Unregister-Event -SourceIdentifier $progressHandler.Name
        Unregister-Event -SourceIdentifier $completedHandler.Name
        $stitch.Dispose()
        return
    }
    Update-Output "Инициализация прошла успешно."

    # Этап 1: Выравнивание
    Update-Output "Начало выравнивания..."
    $stitch.StartAligning()
    $taskCompleted.WaitOne([System.TimeSpan]::FromSeconds(10)) | Out-Null
    if ($stitch.AlignedCount -lt 2 -or $stitch.HasLastError) {
        Update-Output "Ошибка при выравнивании."
        Unregister-Event -SourceIdentifier $progressHandler.Name
        Unregister-Event -SourceIdentifier $completedHandler.Name
        $stitch.Dispose()
        return
    }
    Update-Output "Выравнивание прошло успешно."

    # Этап 2: Композитинг
    Update-Output "Начало композиции..."
    $stitch.StartCompositing()
    $taskCompleted.WaitOne([System.TimeSpan]::FromSeconds(10)) | Out-Null
    if ($stitch.HasLastError) {
        Update-Output "Ошибка при композиции."
        Unregister-Event -SourceIdentifier $progressHandler.Name
        Unregister-Event -SourceIdentifier $completedHandler.Name
        $stitch.Dispose()
        return
    }
    Update-Output "Композиция прошла успешно."

    # Этап 3: Проецирование
    Update-Output "Начало проекции..."
    $stitch.StartProjecting()
    $taskCompleted.WaitOne([System.TimeSpan]::FromSeconds(10)) | Out-Null
    if ($stitch.HasLastError) {
        Update-Output "Ошибка при проекции."
        Unregister-Event -SourceIdentifier $progressHandler.Name
        Unregister-Event -SourceIdentifier $completedHandler.Name
        $stitch.Dispose()
        return
    }
    Update-Output "Проекция прошла успешно."

    # Ожидание инициализации ResetCropRect
    Update-Output "Ожидание инициализации ResetCropRect..."
    $wait = 0
    while (($stitch.ResetCropRect -eq $null) -and ($wait -lt 10)) {
        Start-Sleep -Seconds 1
        $wait++
    }

    if ($stitch.ResetCropRect -ne $null) {
        $cropRect = $stitch.ResetCropRect
    } else {
        Update-Output "ResetCropRect не инициализирован. Используем значение по умолчанию."
        Add-Type -AssemblyName WindowsBase
        $cropRect = [System.Windows.Int32Rect]::Empty
    }

    # Этап 4: Экспорт
    Update-Output "Начало экспорта..."
    $exportFormat = [Microsoft.Research.ICE.Stitching.ExportFormat]::JPEG
    $outputOptions = New-Object Microsoft.Research.ICE.Stitching.OutputOptions($exportFormat, 75, $true, $false, $false)
    $outputFileName = "final" + "{0:D4}" -f ($global:taskCounter) + ".jpg"
    $outputPath = Join-Path -Path $outputFolder -ChildPath $outputFileName

    try {
        $stitch.StartExporting($outputPath, $cropRect, 1, $outputOptions, $false)
        Update-Output "Экспорт завершен: $outputFileName"
    } catch {
        Update-Output "Ошибка при экспорте: $_"
    }

    $global:taskCounter++
    Update-Output "Удаление файлов в папке $inputFolder..."
    Get-ChildItem -Path $inputFolder -Filter *.jpg | Remove-Item -Force

    Unregister-Event -SourceIdentifier $progressHandler.Name
    Unregister-Event -SourceIdentifier $completedHandler.Name
    if ($stitch -and $stitch.Dispose) { $stitch.Dispose() }
    Update-Output "Работа завершена."
}

# Счетчик задач
$global:taskCounter = 1

# Действие при нажатии кнопки "Начать Сшивание"
$startButton.Add_Click({
    Update-Output "Процесс сшивания начинается..."
    Start-StitchingProcess
})

# Показываем форму
$form.ShowDialog()
