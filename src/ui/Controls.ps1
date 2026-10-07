# Small factories for building UI elements in code. Brushes are attached as
# dynamic resource references so theme switches repaint everything.

function Get-WKGlyph {
    param([Parameter(Mandatory)][string]$Code)
    return [string][char][Convert]::ToInt32($Code, 16)
}

function Set-WKBrush {
    param(
        [Parameter(Mandatory)][System.Windows.FrameworkElement]$Element,
        [Parameter(Mandatory)][System.Windows.DependencyProperty]$Property,
        [Parameter(Mandatory)][string]$Key
    )
    $Element.SetResourceReference($Property, $Key)
}

function New-WKThickness {
    param([double]$Left = 0, [double]$Top = 0, [double]$Right = 0, [double]$Bottom = 0)
    return New-Object System.Windows.Thickness($Left, $Top, $Right, $Bottom)
}

function New-WKText {
    param(
        [AllowEmptyString()][string]$Text = '',
        [string]$Style,
        [string]$Brush,
        [double]$Size = 0,
        [switch]$Bold,
        [switch]$SemiBold,
        [switch]$Wrap,
        [switch]$Trim,
        [System.Windows.Thickness]$Margin
    )
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    if ($Style) { $t.Style = $script:UI.Window.FindResource($Style) }
    if ($Brush) { Set-WKBrush $t ([System.Windows.Controls.TextBlock]::ForegroundProperty) $Brush }
    if ($Size -gt 0) { $t.FontSize = $Size }
    if ($Bold) { $t.FontWeight = [System.Windows.FontWeights]::Bold }
    if ($SemiBold) { $t.FontWeight = [System.Windows.FontWeights]::SemiBold }
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    if ($Trim) { $t.TextTrimming = 'CharacterEllipsis' }
    if ($Margin) { $t.Margin = $Margin }
    return $t
}

function New-WKIcon {
    param(
        [Parameter(Mandatory)][string]$Code,
        [string]$Brush,
        [double]$Size = 15
    )
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Style = $script:UI.Window.FindResource('Icon')
    $t.Text = Get-WKGlyph $Code
    $t.FontSize = $Size
    if ($Brush) { Set-WKBrush $t ([System.Windows.Controls.TextBlock]::ForegroundProperty) $Brush }
    return $t
}

function New-WKPill {
    <# Small rounded status label. Kind: Good, Warn, Bad, Info, Accent, Neutral. #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('Good', 'Warn', 'Bad', 'Info', 'Accent', 'Neutral')][string]$Kind = 'Neutral',
        [string]$ToolTip
    )
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $b.Padding = New-WKThickness 9 2 9 3
    $b.VerticalAlignment = 'Center'
    $b.Child = New-WKText -Size 11.5 -SemiBold
    Set-WKPill -Pill $b -Text $Text -Kind $Kind -ToolTip $ToolTip
    return $b
}

function Set-WKPill {
    param(
        [Parameter(Mandatory)][System.Windows.Controls.Border]$Pill,
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('Good', 'Warn', 'Bad', 'Info', 'Accent', 'Neutral')][string]$Kind = 'Neutral',
        [string]$ToolTip
    )
    $keys = @{
        Good    = @('GoodSoftBrush', 'GoodBrush')
        Warn    = @('WarnSoftBrush', 'WarnBrush')
        Bad     = @('BadSoftBrush', 'BadBrush')
        Info    = @('InfoSoftBrush', 'InfoBrush')
        Accent  = @('AccentSoftBrush', 'AccentBrush')
        Neutral = @('HoverBrush', 'MutedBrush')
    }[$Kind]
    Set-WKBrush $Pill ([System.Windows.Controls.Border]::BackgroundProperty) $keys[0]
    $Pill.Child.Text = $Text
    Set-WKBrush $Pill.Child ([System.Windows.Controls.TextBlock]::ForegroundProperty) $keys[1]
    if ($ToolTip) { $Pill.ToolTip = $ToolTip } else { $Pill.ClearValue([System.Windows.FrameworkElement]::ToolTipProperty) }
}

function New-WKButton {
    param(
        [Parameter(Mandatory)]$Content,
        [string]$Style = 'Btn',
        $Tag,
        [string]$Icon,
        [System.Windows.Thickness]$Margin,
        [string]$ToolTip
    )
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $script:UI.Window.FindResource($Style)
    if ($Icon) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $i = New-WKIcon -Code $Icon -Size 12
        [void]$sp.Children.Add($i)
        $t = New-WKText -Text $Content -Margin (New-WKThickness 7 0 0 0)
        [void]$sp.Children.Add($t)
        $b.Content = $sp
    }
    else { $b.Content = $Content }
    if ($null -ne $Tag) { $b.Tag = $Tag }
    if ($Margin) { $b.Margin = $Margin }
    if ($ToolTip) { $b.ToolTip = $ToolTip }
    return $b
}

function New-WKCard {
    param([System.Windows.Thickness]$Margin, [System.Windows.Thickness]$Padding)
    $b = New-Object System.Windows.Controls.Border
    $b.Style = $script:UI.Window.FindResource('Card')
    if ($Margin) { $b.Margin = $Margin }
    if ($Padding) { $b.Padding = $Padding }
    return $b
}

function New-WKDivider {
    $b = New-Object System.Windows.Controls.Border
    $b.Height = 1
    Set-WKBrush $b ([System.Windows.Controls.Border]::BackgroundProperty) 'LineBrush'
    return $b
}

function New-WKGrid {
    param([string[]]$Columns = @('*'))
    $g = New-Object System.Windows.Controls.Grid
    foreach ($c in $Columns) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = switch -Regex ($c) {
            '^Auto$'     { [System.Windows.GridLength]::Auto }
            '^\*$'       { New-Object System.Windows.GridLength(1, 'Star') }
            '^(\d+)\*$'  { New-Object System.Windows.GridLength([double]$Matches[1], 'Star') }
            default      { New-Object System.Windows.GridLength([double]$c) }
        }
        [void]$g.ColumnDefinitions.Add($cd)
    }
    return $g
}

function Add-WKGridChild {
    param(
        [Parameter(Mandatory)][System.Windows.Controls.Grid]$Grid,
        [Parameter(Mandatory)][System.Windows.UIElement]$Child,
        [int]$Column = 0
    )
    [System.Windows.Controls.Grid]::SetColumn($Child, $Column)
    [void]$Grid.Children.Add($Child)
}

function New-WKStack {
    param([switch]$Horizontal, [System.Windows.Thickness]$Margin)
    $s = New-Object System.Windows.Controls.StackPanel
    if ($Horizontal) { $s.Orientation = 'Horizontal' }
    if ($Margin) { $s.Margin = $Margin }
    return $s
}

function New-WKStatusIcon {
    <# Round colored badge with a glyph, used in check and history lists. #>
    param(
        [Parameter(Mandatory)][ValidateSet('Good', 'Info', 'Warning', 'Critical', 'Accent', 'Neutral', 'Network')][string]$Status,
        [double]$Size = 30
    )
    $map = @{
        Good     = @('GoodSoftBrush', 'GoodBrush', 'E73E')
        Info     = @('InfoSoftBrush', 'InfoBrush', 'E946')
        Warning  = @('WarnSoftBrush', 'WarnBrush', 'E7BA')
        Critical = @('BadSoftBrush', 'BadBrush', 'E711')
        Accent   = @('AccentSoftBrush', 'AccentBrush', 'E9E9')
        Neutral  = @('HoverBrush', 'MutedBrush', 'E81C')
        Network  = @('InfoSoftBrush', 'InfoBrush', 'E774')
    }
    $b = New-Object System.Windows.Controls.Border
    $b.Width = $Size
    $b.Height = $Size
    $b.CornerRadius = New-Object System.Windows.CornerRadius($Size / 2)
    $b.VerticalAlignment = 'Center'
    Set-WKBrush $b ([System.Windows.Controls.Border]::BackgroundProperty) $map[$Status][0]
    $icon = New-WKIcon -Code $map[$Status][2] -Brush $map[$Status][1] -Size ([math]::Round($Size * 0.42))
    $icon.HorizontalAlignment = 'Center'
    $b.Child = $icon
    return $b
}

function Open-WKExternal {
    <#
        Opens a URL, settings page or folder through Explorer so it runs in
        the user's normal (non-elevated) context rather than as administrator.
    #>
    param([Parameter(Mandatory)][string]$Target)
    try {
        Start-Process -FilePath (Get-WKWindowsPath 'explorer.exe') -ArgumentList "`"$Target`""
    }
    catch {
        Show-WKToast "Could not open $Target" -Kind Error
    }
}
