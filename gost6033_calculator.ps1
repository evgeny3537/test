
#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

using namespace System.Globalization
$ru = [CultureInfo]::GetCultureInfo('ru-RU')

function Parse-Double {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return [double]::NaN }
    $t = $Text.Trim().Replace(',', '.')
    $n = 0.0
    if ([double]::TryParse($t, [NumberStyles]::Float, [CultureInfo]::InvariantCulture, [ref]$n)) {
        return $n
    }
    return [double]::NaN
}

function Fmt {
    param([double]$Value, [int]$Digits = 3)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return '—' }
    return $Value.ToString("0." + ('0' * $Digits), $ru).TrimEnd('0').TrimEnd(',')
}

function New-Label {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 230)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, 20)
    $Parent.Controls.Add($l)
    return $l
}

function New-TextBox {
    param($Parent, [int]$X, [int]$Y, [int]$W = 90, [string]$Default = '')
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Size = New-Object System.Drawing.Size($W, 22)
    $t.Text = $Default
    $Parent.Controls.Add($t)
    return $t
}

function Add-FieldRows {
    param(
        $GroupBox,
        [array]$Specs,
        [int]$StartY = 28,
        [int]$LabelW = 245,
        [int]$BoxX = 260,
        [string]$Prefix = ''
    )
    $controls = @{}
    $y = $StartY
    foreach ($spec in $Specs) {
        New-Label -Parent $GroupBox -Text $spec.Label -X 12 -Y $y -W $LabelW | Out-Null
        $tb = New-TextBox -Parent $GroupBox -X $BoxX -Y $y -W $spec.Width -Default $spec.Default
        $controls[$Prefix + $spec.Key] = $tb
        $y += 28
    }
    return $controls
}

function Get-Fields {
    param($Map)
    $out = @{}
    foreach ($k in $Map.Keys) { $out[$k] = $Map[$k].Text }
    return $out
}

function Save-Inputs {
    param([hashtable]$Map, [string]$Path)
    $data = @{}
    foreach ($k in $Map.Keys) { $data[$k] = $Map[$k].Text }
    $json = $data | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Load-Inputs {
    param([hashtable]$Map, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($k in $Map.Keys) {
        if ($null -ne $data.$k) { $Map[$k].Text = [string]$data.$k }
    }
    return $true
}

function Calculate-Gost6033 {
    param(
        [hashtable]$Fields,
        [bool]$ShowSteps,
        [bool]$CenterByOuterDiameter,
        [bool]$RoundedBottom
    )

    $m    = Parse-Double $Fields['M']
    $alphaDeg = Parse-Double $Fields['UD']
    $z1   = Parse-Double $Fields['Z1']
    $z2   = Parse-Double $Fields['Z2']
    $x1   = Parse-Double $Fields['X1']
    $x2   = Parse-Double $Fields['X2']
    $dr   = Parse-Double $Fields['DRD']   # диаметр ролика
    $D1   = Parse-Double $Fields['DL1']
    $D2   = Parse-Double $Fields['DL2']

    $errs = @()
    foreach ($pair in @(
        @{N='M'; V=$m; T='Модуль'},
        @{N='UD'; V=$alphaDeg; T='Угол профиля'},
        @{N='Z1'; V=$z1; T='Число зубьев детали'},
        @{N='Z2'; V=$z2; T='Число зубьев сопряженной детали'},
        @{N='X1'; V=$x1; T='Коэффициент смещения детали'},
        @{N='X2'; V=$x2; T='Коэффициент смещения сопряженной детали'}
    )) {
        if ([double]::IsNaN($pair.V)) { $errs += $pair.T }
    }
    if ($errs.Count -gt 0) {
        throw "Не заполнены или некорректны поля: $($errs -join ', ')"
    }

    $alpha = $alphaDeg * [Math]::PI / 180.0
    $p = [Math]::PI * $m
    $d1 = $m * $z1
    $d2 = $m * $z2
    $db1 = $d1 * [Math]::Cos($alpha)
    $db2 = $d2 * [Math]::Cos($alpha)

    # Табличные зависимости ГОСТ 6033-80 (основные геометрические формулы)
    $D_basic1 = $m * $z1 + 2 * $x1 * $m + 1.1 * $m
    $D_basic2 = $m * $z2 + 2 * $x2 * $m + 1.1 * $m

    $xm1 = 0.5 * ($D_basic1 - $m * $z1 - 1.1 * $m)
    $xm2 = 0.5 * ($D_basic2 - $m * $z2 - 1.1 * $m)

    $s1 = ([Math]::PI / 2.0) * $m + 2 * $x1 * $m * [Math]::Tan($alpha)
    $s2 = ([Math]::PI / 2.0) * $m + 2 * $x2 * $m * [Math]::Tan($alpha)
    $e1 = ([Math]::PI / 2.0) * $m - 2 * $x1 * $m * [Math]::Tan($alpha)
    $e2 = ([Math]::PI / 2.0) * $m - 2 * $x2 * $m * [Math]::Tan($alpha)

    $ha_shaft = if ($CenterByOuterDiameter) { 0.55 * $m } else { 0.45 * $m }
    $Ha_hub   = 0.45 * $m
    $hf_shaft = if ($RoundedBottom) { 0.83 * $m } else { 0.55 * $m }
    $Hf_hub   = if ($RoundedBottom) { 0.77 * $m } else { 0.55 * $m }

    $h_shaft = $ha_shaft + $hf_shaft
    $H_hub   = $Ha_hub + $Hf_hub

    $Df_hub = if ($RoundedBottom) { $D_basic1 + 0.44 * $m } else { $D_basic1 }
    $Da_hub = $D_basic1 - 2 * $m
    $df_shaft = if ($RoundedBottom) { $D_basic1 - 2.76 * $m } else { $D_basic1 - 2.2 * $m }
    $da_shaft = if ($CenterByOuterDiameter) { $D_basic1 } else { $D_basic1 - 0.2 * $m }

    $cmin = 0.1 * $m
    $k = 0.15 * $m

    $sx_shaft = $s1 * [Math]::Pow([Math]::Cos($alpha), 2)
    $sx_hub   = $e1 * [Math]::Pow([Math]::Cos($alpha), 2)
    $hx_shaft  = 0.5 * ($da_shaft - $d1 - $sx_shaft * [Math]::Tan($alpha))
    $hx_hub    = 0.5 * ($Da_hub - $d1 - $sx_hub   * [Math]::Tan($alpha))

    $dl_min = $Da_hub - $dr
    $Dl_min = $da_shaft + $dr

    $result = New-Object System.Text.StringBuilder
    $append = {
        param([string]$line)
        [void]$result.AppendLine($line)
    }

    & $append "ГОСТ 6033-80 — расчет эвольвентного шлицевого соединения"
    & $append ("Модуль m = {0} мм" -f (Fmt $m))
    & $append ("Угол профиля α = {0}°" -f (Fmt $alphaDeg 2))
    & $append ("Окружной шаг p = π·m = {0} мм" -f (Fmt $p))
    & $append ""

    if ($ShowSteps) {
        & $append "1) Основные диаметры:"
        & $append ("   d1 = m·z1 = {0} мм" -f (Fmt $d1))
        & $append ("   d2 = m·z2 = {0} мм" -f (Fmt $d2))
        & $append ("   db1 = d1·cos α = {0} мм" -f (Fmt $db1))
        & $append ("   db2 = d2·cos α = {0} мм" -f (Fmt $db2))
        & $append ""
        & $append "2) Основной (исходный) диаметр и смещение контура:"
        & $append ("   D1 = m·z1 + 2·x1·m + 1.1·m = {0} мм" -f (Fmt $D_basic1))
        & $append ("   D2 = m·z2 + 2·x2·m + 1.1·m = {0} мм" -f (Fmt $D_basic2))
        & $append ("   xm1 = 1/2·(D1 - m·z1 - 1.1·m) = {0} мм" -f (Fmt $xm1))
        & $append ("   xm2 = 1/2·(D2 - m·z2 - 1.1·m) = {0} мм" -f (Fmt $xm2))
        & $append ""
        & $append "3) Делительная толщина зуба / ширина впадины:"
        & $append ("   s1 = (π/2)·m + 2·xm1·m·tg α = {0} мм" -f (Fmt $s1))
        & $append ("   e1 = (π/2)·m - 2·xm1·m·tg α = {0} мм" -f (Fmt $e1))
        & $append ("   s2 = (π/2)·m + 2·xm2·m·tg α = {0} мм" -f (Fmt $s2))
        & $append ("   e2 = (π/2)·m - 2·xm2·m·tg α = {0} мм" -f (Fmt $e2))
        & $append ""
        & $append "4) Высоты зубьев по ГОСТ:"
        & $append ("   ha (вал) = {0} мм" -f (Fmt $ha_shaft))
        & $append ("   Ha (втулка) = {0} мм" -f (Fmt $Ha_hub))
        & $append ("   hf (вал) = {0} мм" -f (Fmt $hf_shaft))
        & $append ("   Hf (втулка) = {0} мм" -f (Fmt $Hf_hub))
        & $append ("   h (вал) = {0} мм" -f (Fmt $h_shaft))
        & $append ("   H (втулка) = {0} мм" -f (Fmt $H_hub))
        & $append ""
        & $append "5) Контрольные и справочные размеры:"
        & $append ("   Df (втулка) = {0} мм" -f (Fmt $Df_hub))
        & $append ("   Da (втулка) = {0} мм" -f (Fmt $Da_hub))
        & $append ("   df (вал) = {0} мм" -f (Fmt $df_shaft))
        & $append ("   da (вал) = {0} мм" -f (Fmt $da_shaft))
        & $append ("   cmin = 0.1·m = {0} мм" -f (Fmt $cmin))
        & $append ("   k = 0.15·m = {0} мм" -f (Fmt $k))
        & $append ("   sx (вал, по постоянной хорде) = {0} мм" -f (Fmt $sx_shaft))
        & $append ("   hx (вал, по постоянной хорде) = {0} мм" -f (Fmt $hx_shaft))
        & $append ("   sx (втулка, по постоянной хорде) = {0} мм" -f (Fmt $sx_hub))
        & $append ("   hx (втулка, по постоянной хорде) = {0} мм" -f (Fmt $hx_hub))
        & $append ("   Dl(min) = da + Fr = {0} мм" -f (Fmt $Dl_min))
        & $append ("   dl(min) = Da - Fr = {0} мм" -f (Fmt $dl_min))
    }
    else {
        & $append ("d1 = {0} мм, d2 = {1} мм" -f (Fmt $d1, Fmt $d2))
        & $append ("db1 = {0} мм, db2 = {1} мм" -f (Fmt $db1, Fmt $db2))
        & $append ("D1 = {0} мм, D2 = {1} мм" -f (Fmt $D_basic1, Fmt $D_basic2))
        & $append ("s1 = {0} мм, e1 = {1} мм" -f (Fmt $s1, Fmt $e1))
        & $append ("ha = {0} мм, hf = {1} мм" -f (Fmt $ha_shaft, $hf_shaft))
        & $append ("Da = {0} мм, df = {1} мм, da = {2} мм" -f (Fmt $Da_hub, Fmt $df_shaft, Fmt $da_shaft))
    }

    # Сравнение с введёнными D1 / D2, если пользователь заполнил поля
    if (-not [double]::IsNaN($D1)) {
        & $append ""
        & $append ("Проверка D1 (введено): Δ = {0} мм" -f (Fmt ($D1 - $D_basic1)))
    }
    if (-not [double]::IsNaN($D2)) {
        & $append ("Проверка D2 (введено): Δ = {0} мм" -f (Fmt ($D2 - $D_basic2)))
    }

    return $result.ToString()
}

# ------------------------- GUI -------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Расчёт червячной фрезы и шлицев по ГОСТ 6033-80'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1310, 860)
$form.MinimumSize = New-Object System.Drawing.Size(1280, 820)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'Исходные параметры для расчета эвольвентного шлицевого соединения (ГОСТ 6033-80)'
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(18, 12)
$form.Controls.Add($lblTitle)

$grpTool = New-Object System.Windows.Forms.GroupBox
$grpTool.Text = 'Исходные данные фрезы'
$grpTool.Location = New-Object System.Drawing.Point(18, 46)
$grpTool.Size = New-Object System.Drawing.Size(390, 350)
$form.Controls.Add($grpTool)

$grpPart = New-Object System.Windows.Forms.GroupBox
$grpPart.Text = 'Исходные данные обрабатываемой детали'
$grpPart.Location = New-Object System.Drawing.Point(418, 46)
$grpPart.Size = New-Object System.Drawing.Size(410, 560)
$form.Controls.Add($grpPart)

$grpMate = New-Object System.Windows.Forms.GroupBox
$grpMate.Text = 'Исходные данные сопряженной детали'
$grpMate.Location = New-Object System.Drawing.Point(838, 46)
$grpMate.Size = New-Object System.Drawing.Size(445, 170)
$form.Controls.Add($grpMate)

$grpOpts = New-Object System.Windows.Forms.GroupBox
$grpOpts.Text = 'Параметры расчета'
$grpOpts.Location = New-Object System.Drawing.Point(838, 226)
$grpOpts.Size = New-Object System.Drawing.Size(445, 160)
$form.Controls.Add($grpOpts)

$toolSpecs = @(
    @{Key='M';   Label='Модуль нормальный (M)';            Default='2';   Width=95},
    @{Key='UD';  Label='Угол профиля (UD), °';             Default='30';  Width=95},
    @{Key='ZU';  Label='Число зубьев фрезы (ZU)';          Default='8';   Width=95},
    @{Key='DLU'; Label='Наружный диаметр фрезы (DLU)';     Default='—';   Width=95},
    @{Key='UU';  Label='Угол наклона усика (UU), °';       Default='—';   Width=95},
    @{Key='J';   Label='Угол фланка (J), °';               Default='—';   Width=95},
    @{Key='AV';  Label='Задний угол (AV), °';              Default='—';   Width=95},
    @{Key='U';   Label='Число заходов (U)';                 Default='—';   Width=95},
    @{Key='DL';  Label='Длина фрезы (DL)';                 Default='—';   Width=95},
    @{Key='CL';  Label='Класс точности (CL)';              Default='7';   Width=95}
)
$partSpecs = @(
    @{Key='Z1';   Label='Число зубьев (Z1)';                        Default='24';  Width=100},
    @{Key='DL1';  Label='Наружный диаметр (DL1)';                  Default='—';   Width=100},
    @{Key='X1';   Label='Коэффициент смещения (X1)';              Default='0';   Width=100},
    @{Key='NAPR'; Label='Напр. линии зуба (NAPR, при левом πшем -)'; Default='—'; Width=100},
    @{Key='B';    Label='Угол наклона линии зуба (B), °';          Default='—';   Width=100},
    @{Key='H1';   Label='Высота головки зуба (H1)';                Default='—';   Width=100},
    @{Key='H';    Label='Полная высота зуба (H)';                  Default='—';   Width=100},
    @{Key='SD1';  Label='Толщина зуба по I оконч. (SD1)';          Default='—';   Width=100},
    @{Key='SD2';  Label='Дуге дел. окр. I под шевинг. (SD2)';      Default='—';   Width=100},
    @{Key='L1';   Label='Длина общей нормали (оконч.) (L1)';        Default='—';   Width=100},
    @{Key='L2';   Label='Длина общей нормали под шевинг. (L2)';     Default='—';   Width=100},
    @{Key='ZN';   Label='Число зубьев в дл. общей нормали (ZN)';    Default='—';   Width=100},
    @{Key='MR1';  Label='Размер по роликам (оконч.) (MR1)';         Default='—';   Width=100},
    @{Key='MR2';  Label='Размер по роликам под шевинг. (MR2)';      Default='—';   Width=100},
    @{Key='DRD';  Label='Диаметр ролика (DRD)';                     Default='6';   Width=100},
    @{Key='HD';   Label='Коэф. высоты головки зуба (HD)';           Default='—';   Width=100},
    @{Key='DELTA';Label='Коэф. глубины головки зуба (DELTA)';       Default='—';   Width=100},
    @{Key='A12';  Label='Межосевое расстояние (A12)';               Default='—';   Width=100}
)
$mateSpecs = @(
    @{Key='Z2';   Label='Число зубьев (Z2)';                 Default='24'; Width=110},
    @{Key='DL2';  Label='Наружный диаметр (DL2)';           Default='—';  Width=110},
    @{Key='X2';   Label='Коэф. смещения (X2)';               Default='0';  Width=110}
)

$toolMap = Add-FieldRows -GroupBox $grpTool -Specs $toolSpecs -StartY 28 -LabelW 250 -BoxX 270 -Prefix 'T_'
$partMap = Add-FieldRows -GroupBox $grpPart -Specs $partSpecs -StartY 28 -LabelW 290 -BoxX 305 -Prefix 'P_'
$mateMap = Add-FieldRows -GroupBox $grpMate -Specs $mateSpecs -StartY 28 -LabelW 250 -BoxX 270 -Prefix 'M_'

# Параметры расчета
$rbCenterFlank = New-Object System.Windows.Forms.RadioButton
$rbCenterFlank.Text = 'Центрирование по боковым поверхностям'
$rbCenterFlank.Location = New-Object System.Drawing.Point(12, 30)
$rbCenterFlank.Size = New-Object System.Drawing.Size(360, 22)
$rbCenterFlank.Checked = $true
$grpOpts.Controls.Add($rbCenterFlank)

$rbCenterOuter = New-Object System.Windows.Forms.RadioButton
$rbCenterOuter.Text = 'Центрирование по наружному диаметру'
$rbCenterOuter.Location = New-Object System.Drawing.Point(12, 54)
$rbCenterOuter.Size = New-Object System.Drawing.Size(360, 22)
$grpOpts.Controls.Add($rbCenterOuter)

$rbFlat = New-Object System.Windows.Forms.RadioButton
$rbFlat.Text = 'Плоская форма дна впадины'
$rbFlat.Location = New-Object System.Drawing.Point(12, 86)
$rbFlat.Size = New-Object System.Drawing.Size(250, 22)
$rbFlat.Checked = $true
$grpOpts.Controls.Add($rbFlat)

$rbRounded = New-Object System.Windows.Forms.RadioButton
$rbRounded.Text = 'Закругленная форма дна впадины'
$rbRounded.Location = New-Object System.Drawing.Point(12, 110)
$rbRounded.Size = New-Object System.Drawing.Size(280, 22)
$grpOpts.Controls.Add($rbRounded)

# Buttons row
$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = 'Загрузить'
$btnLoad.Location = New-Object System.Drawing.Point(18, 410)
$btnLoad.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnLoad)

$btnCalc = New-Object System.Windows.Forms.Button
$btnCalc.Text = 'Результаты'
$btnCalc.Location = New-Object System.Drawing.Point(126, 410)
$btnCalc.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnCalc)

$btnStep = New-Object System.Windows.Forms.Button
$btnStep.Text = 'ПОШАГОВО'
$btnStep.Location = New-Object System.Drawing.Point(234, 410)
$btnStep.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnStep)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Сохранить'
$btnSave.Location = New-Object System.Drawing.Point(342, 410)
$btnSave.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnSave)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Очистить'
$btnClear.Location = New-Object System.Drawing.Point(450, 410)
$btnClear.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnClear)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = 'Выход'
$btnExit.Location = New-Object System.Drawing.Point(558, 410)
$btnExit.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnExit)

$btnInv = New-Object System.Windows.Forms.Button
$btnInv.Text = 'Расчёт инволюты'
$btnInv.Location = New-Object System.Drawing.Point(838, 392)
$btnInv.Size = New-Object System.Drawing.Size(150, 30)
$form.Controls.Add($btnInv)

$btnDraw = New-Object System.Windows.Forms.Button
$btnDraw.Text = 'Чертёж'
$btnDraw.Location = New-Object System.Drawing.Point(995, 392)
$btnDraw.Size = New-Object System.Drawing.Size(100, 30)
$btnDraw.Enabled = $false
$form.Controls.Add($btnDraw)

# Result area
$grpRes = New-Object System.Windows.Forms.GroupBox
$grpRes.Text = 'Результат расчета'
$grpRes.Location = New-Object System.Drawing.Point(18, 452)
$grpRes.Size = New-Object System.Drawing.Size(1265, 340)
$form.Controls.Add($grpRes)

$lblName = New-Object System.Windows.Forms.Label
$lblName.Text = 'Название полученной величины'
$lblName.Location = New-Object System.Drawing.Point(14, 28)
$lblName.Size = New-Object System.Drawing.Size(260, 20)
$grpRes.Controls.Add($lblName)

$txtName = New-Object System.Windows.Forms.TextBox
$txtName.Location = New-Object System.Drawing.Point(16, 50)
$txtName.Size = New-Object System.Drawing.Size(1230, 24)
$txtName.ReadOnly = $true
$grpRes.Controls.Add($txtName)

$lblFormula = New-Object System.Windows.Forms.Label
$lblFormula.Text = 'Формула и результат'
$lblFormula.Location = New-Object System.Drawing.Point(14, 82)
$lblFormula.Size = New-Object System.Drawing.Size(200, 20)
$grpRes.Controls.Add($lblFormula)

$txtResult = New-Object System.Windows.Forms.TextBox
$txtResult.Location = New-Object System.Drawing.Point(16, 104)
$txtResult.Size = New-Object System.Drawing.Size(1230, 220)
$txtResult.Multiline = $true
$txtResult.ScrollBars = 'Vertical'
$txtResult.ReadOnly = $true
$txtResult.Font = New-Object System.Drawing.Font('Consolas', 9)
$grpRes.Controls.Add($txtResult)

$allMaps = @{}
$allMaps += $toolMap
$allMaps += $partMap
$allMaps += $mateMap

$defaultsPath = Join-Path $PSScriptRoot 'gost6033_inputs.json'

function Refresh-Calculation {
    try {
        $fields = Get-Fields $allMaps
        $text = Calculate-Gost6033 -Fields $fields -ShowSteps $script:ShowSteps -CenterByOuterDiameter $rbCenterOuter.Checked -RoundedBottom $rbRounded.Checked
        $txtName.Text = 'Эвольвентное шлицевое соединение по ГОСТ 6033-80'
        $txtResult.Text = $text
    }
    catch {
        $txtName.Text = 'Ошибка'
        $txtResult.Text = $_.Exception.Message
    }
}

$script:ShowSteps = $false

$btnCalc.Add_Click({
    $script:ShowSteps = $false
    Refresh-Calculation
})

$btnStep.Add_Click({
    $script:ShowSteps = $true
    Refresh-Calculation
})

$btnLoad.Add_Click({
    # Пример из учебной практики / просто стартовые значения
    $toolMap['T_M'].Text = '2'
    $toolMap['T_UD'].Text = '30'
    $toolMap['T_ZU'].Text = '8'
    $toolMap['T_DLU'].Text = '60'
    $toolMap['T_UU'].Text = '—'
    $toolMap['T_J'].Text = '—'
    $toolMap['T_AV'].Text = '—'
    $toolMap['T_U'].Text = '1'
    $toolMap['T_DL'].Text = '—'
    $toolMap['T_CL'].Text = '7'

    $partMap['P_Z1'].Text = '24'
    $partMap['P_DL1'].Text = '50'
    $partMap['P_X1'].Text = '0'
    $partMap['P_NAPR'].Text = '—'
    $partMap['P_B'].Text = '—'
    $partMap['P_H1'].Text = '—'
    $partMap['P_H'].Text = '—'
    $partMap['P_SD1'].Text = '—'
    $partMap['P_SD2'].Text = '—'
    $partMap['P_L1'].Text = '—'
    $partMap['P_L2'].Text = '—'
    $partMap['P_ZN'].Text = '—'
    $partMap['P_MR1'].Text = '—'
    $partMap['P_MR2'].Text = '—'
    $partMap['P_DRD'].Text = '6'
    $partMap['P_HD'].Text = '—'
    $partMap['P_DELTA'].Text = '—'
    $partMap['P_A12'].Text = '—'

    $mateMap['M_Z2'].Text = '24'
    $mateMap['M_DL2'].Text = '50'
    $mateMap['M_X2'].Text = '0'

    $txtName.Text = 'Данные загружены'
    $txtResult.Text = 'Введен стартовый набор значений. Нажмите «Результаты» или «ПОШАГОВО».'
})

$btnSave.Add_Click({
    try {
        Save-Inputs -Map $allMaps -Path $defaultsPath
        $txtName.Text = 'Сохранение'
        $txtResult.Text = "Входные данные сохранены в:`r`n$defaultsPath"
    }
    catch {
        $txtName.Text = 'Ошибка'
        $txtResult.Text = $_.Exception.Message
    }
})

$btnClear.Add_Click({
    foreach ($tb in $allMaps.Values) { $tb.Clear() }
    $txtName.Clear()
    $txtResult.Clear()
})

$btnExit.Add_Click({ $form.Close() })

$btnInv.Add_Click({
    $script:ShowSteps = $true
    Refresh-Calculation
})

$form.Add_Shown({
    if (Test-Path -LiteralPath $defaultsPath) {
        [void](Load-Inputs -Map $allMaps -Path $defaultsPath)
    }
})

[void]$form.ShowDialog()
