# Render the production form offscreen; never display a window or change audio.
$ErrorActionPreference='Stop'
$setupPath=Join-Path $PSScriptRoot '..\Setup.ps1'
. $setupPath -NoUi
function Assert($value,[string]$message){if(-not $value){throw $message}}
function Get-SetupDevices {
  @([pscustomobject]@{id='virtual';name='CABLE In 16ch (VB-Audio Virtual Cable)';isSpdif=$false},
    [pscustomobject]@{id='optical';name='SPDIF Out (USB Sound Device)';isSpdif=$true})
}
function Get-SetupHardware {[pscustomobject]@{Attached=$true;Installed=$true;ErrorText=$null}}
function Get-SetupSavedOutput {'optical'}
function Get-SetupStartupChoice {$true}
$output=Join-Path $PSScriptRoot 'output\setup-surroundforge.png'
New-Item -ItemType Directory -Path (Split-Path $output -Parent) -Force | Out-Null
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($setupPath,[ref]$tokens,[ref]$errors)
Assert (-not $errors.Count) 'Setup must parse'
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-SetupUi'},$true)
# Replace only the modal presentation call with rendering/assertions; all controls,
# text, sizes, fonts and device refresh come from the production function itself.
$presentation='$form.ShowDialog() | Out-Null'
Assert ($definition.Extent.Text.Contains($presentation)) 'Production presentation hook changed; update this render fixture'
$render=@'
Refresh-SetupUi
Assert ($form.Text -eq 'SurroundForge - Setup') 'Window title must use product name'
Assert ($script:SetupUi.Outputs.SelectedItem.id -eq 'optical') 'Render realistic selected optical output'
Assert ($script:SetupUi.Outputs.Text -eq 'SPDIF Out (USB Sound Device) (optical)') 'Selected optical output label must be visible'
Assert $script:SetupUi.Configure.Enabled 'Ready devices must enable setup'
Assert ($script:SetupUi.Help.Text -notmatch '(?i)Samsung|D\.IN') 'Help must be receiver neutral'
Assert ($script:SetupUi.Help.Text -match 'optical input') 'Help must explain receiver input'
$null=$form.Handle
# DrawToBitmap needs visible child controls. Setting WS_VISIBLE on this never-
# shown form creates its child layout without displaying or activating a window.
function Set-RenderVisible($Control){
  $setState=[Windows.Forms.Control].GetMethod('SetState',[Reflection.BindingFlags]'NonPublic,Instance')
  Assert $setState 'WinForms offscreen state helper unavailable'
  $setState.Invoke($Control,@(2,$true)) | Out-Null
  $Control.CreateControl()
  foreach($child in $Control.Controls){Set-RenderVisible $child}
}
Set-RenderVisible $form
$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
try {
  $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
  # The native ComboBox edit child is omitted by DrawToBitmap. Include its
  # already-asserted production Text using its real font, bounds and colour.
  $graphics=[Drawing.Graphics]::FromImage($bitmap)
  try {
    $border=[int](($form.Width-$form.ClientSize.Width)/2)
    $caption=$form.Height-$form.ClientSize.Height-$border
    $combo=$script:SetupUi.Outputs
    $bounds=New-Object Drawing.Rectangle(($combo.Left+$border+4),($combo.Top+$caption),($combo.Width-24),$combo.Height)
    [Windows.Forms.TextRenderer]::DrawText($graphics,$combo.Text,$combo.Font,$bounds,$combo.ForeColor,
      ([Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::SingleLine))
  } finally {$graphics.Dispose()}
  $darkPixels=0
  for($y=40;$y -lt $bitmap.Height-15;$y+=2){
    for($x=20;$x -lt $bitmap.Width-20;$x+=2){
      $pixel=$bitmap.GetPixel($x,$y)
      if($pixel.R -lt 180 -and $pixel.G -lt 180 -and $pixel.B -lt 180){$darkPixels++}
    }
  }
  Assert ($darkPixels -gt 200) 'Offscreen form must contain rendered content, not a blank body'
  $bitmap.Save($output,[Drawing.Imaging.ImageFormat]::Png)
} finally {$bitmap.Dispose()}
$script:SetupUi.Timer.Dispose()
'@
Invoke-Expression ($definition.Extent.Text.Replace($presentation,$render))
Show-SetupUi
Assert (Test-Path -LiteralPath $output) 'Setup preview was not rendered'
Write-Output "PASS: production setup form rendered offscreen with ready devices; $output"
