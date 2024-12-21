#!/usr/bin/env pwsh
#region    Classes

class CommandLineException : System.Exception {
  CommandLineException() : base() {}

  CommandLineException([string]$message) : base($message) {}

  CommandLineException([string]$message, [Exception]$innerException) : base($message, $innerException) {}
}

class ServiceRequestException : System.Exception {
  [bool]$IsRequestSent
  [object]$PredictorSummary

  ServiceRequestException() : base() {}

  ServiceRequestException([string]$message) : base($message) {}

  ServiceRequestException([string]$message, [Exception]$innerException) : base($message, $innerException) {}
}

class WebSocketClient {
  [string]$ServerUrl = "ws://localhost:8000/ws"
  [System.Net.WebSockets.ClientWebSocket]$WebSocket
  [System.Threading.CancellationTokenSource]$CancellationSource

  WebSocketClient() {
    $this.WebSocket = [System.Net.WebSockets.ClientWebSocket]::new()
    $this.CancellationSource = [System.Threading.CancellationTokenSource]::new()
  }

  [System.Threading.Tasks.Task] Connect() {
    return $this.WebSocket.ConnectAsync([System.Uri]::new($this.ServerUrl), $this.CancellationSource.Token)
  }

  [System.Threading.Tasks.Task[string]] ReceiveMessage() {
    $buffer = [System.Byte[]]::new(4096)
    $result = $this.WebSocket.ReceiveAsync($buffer, $this.CancellationSource.Token)

    return [System.Threading.Tasks.Task[string]]::Run({
        $received = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Result.Count)
        return $received
      })
  }

  [System.Threading.Tasks.Task] SendMessage([string]$message) {
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($message)
    return $this.WebSocket.SendAsync($buffer, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $this.CancellationSource.Token)
  }

  [void] Close() {
    if ($this.WebSocket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
      $this.WebSocket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Closing", $this.CancellationSource.Token).Wait()
    }
    $this.WebSocket.Dispose()
    $this.CancellationSource.Dispose()
  }
}

class Validation {
  static [void] CheckArgument([bool]$argumentCondition, [string]$message) {
    if (-not $argumentCondition) {
      throw [ArgumentException]::new($message)
    }
  }

  static [void] CheckArgument([object]$arg, [string]$message) {
    if ($null -eq $arg) {
      throw [ArgumentNullException]::new($message)
    }
  }

  static [void] CheckInvariant([bool]$variantCondition, [string]$message) {
    if (-not $variantCondition) {
      throw [InvalidOperationException]::new($message)
    }
  }
}

class ExceptionUtilities {
  static [void] RecordExceptionWrapper([scriptblock]$action) {
    try {
      & $action
    } catch {
      Write-Warning "An error occurred: $_"
      # In a real implementation, we would add telemetry here
    }
  }
}

class PowerShellRuntimeUtilities {
  static [System.Management.Automation.Runspaces.Runspace] GetMinimalRunspace() {
    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialSessionState)
    $runspace.Open()
    return $runspace
  }
}

class JsonUtilities {
  static [object] ConvertToJson([object]$inputObject) {
    return $inputObject | ConvertTo-Json -Depth 10 -Compress
  }

  static [object] ConvertFromJson([string]$jsonString) {
    return $jsonString | ConvertFrom-Json
  }
}

class CommandLineUtilities {
  static [string] MaskCommandLine([string]$commandLine) {
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
      return $commandLine
    }

    # Basic masking of sensitive information like passwords and keys
    $maskedLine = $commandLine -replace '(?i)(password|key|secret)[\s=]+[^\s]+', '$1=********'
    return $maskedLine
  }

  static [string] GetCommandName([string]$commandLine) {
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
      return $null
    }

    $tokens = [System.Management.Automation.PSParser]::Tokenize($commandLine, [ref]$null)
    $commandToken = $tokens | Where-Object { $_.Type -eq 'Command' } | Select-Object -First 1

    return $commandToken.Content
  }
}

class PredictionSettings {
  [bool]$IsEnabled = $false
  [int]$SuggestionCount = 5
  [int]$MaxAllowedCommandDuplicate = 3
  [string]$HistoryFilePath

  PredictionSettings() {
    $this.HistoryFilePath = Join-Path $env:APPDATA "PowerShell\CommandHistory.json"
  }
}

class CommandSuggestion {
  [string]$Command
  [string]$Description
  [string]$Source

  CommandSuggestion([string]$command, [string]$description, [string]$source = "Default") {
    $this.Command = $command
    $this.Description = $description
    $this.Source = $source
  }
}

class PredictionContext {
  [string]$InputText
  [int]$CursorPosition
  [System.Management.Automation.Language.Ast]$Ast

  PredictionContext([string]$input, [int]$cursorPos) {
    $this.InputText = $input
    $this.CursorPosition = $cursorPos
    $tokens = $null; $parseErrors = $null
    $this.Ast = [System.Management.Automation.Language.Parser]::ParseInput(
      $input, [ref]$tokens, [ref]$parseErrors
    )
  }
}

class CommandPredictor {
  hidden [System.Collections.Concurrent.ConcurrentDictionary[string, CommandSuggestion]]$CommonCommands
  hidden [System.Collections.Generic.List[string]]$CommandHistory
  hidden [PredictionSettings]$Settings
  hidden [WebSocketClient]$WebSocketClient
  static [string]$Name = "PowerShell AI Predictor"
  static [string]$Description = "Provides AI-powered command predictions"

  CommandPredictor() {
    $this.Settings = [PredictionSettings]::new()
    $this.CommandHistory = [System.Collections.Generic.List[string]]::new()
    $this.CommonCommands = [System.Collections.Concurrent.ConcurrentDictionary[string, CommandSuggestion]]::new()
    $this.WebSocketClient = [WebSocketClient]::new()

    # Initialize connection to Python backend
    try {
      $this.WebSocketClient.Connect().Wait()
    } catch {
      Write-Warning "Failed to connect to prediction server: $_"
    }

    # Load command history if exists
    if (Test-Path $this.Settings.HistoryFilePath) {
      try {
        $savedHistory = Get-Content $this.Settings.HistoryFilePath | ConvertFrom-Json
        foreach ($cmd in $savedHistory) {
          $this.CommandHistory.Add($cmd)
        }
      } catch {
        Write-Warning "Failed to load command history: $_"
      }
    }

    # Register with PSReadLine
    if (Get-Module PSReadLine) {
      Set-PSReadLineOption -PredictionSource HistoryAndPlugin
      $this.Enable()
    }
  }

  [System.Collections.Generic.List[CommandSuggestion]] GetSuggestions([PredictionContext]$context) {
    if (-not $this.Settings.IsEnabled) {
      return $null
    }

    $suggestions = [System.Collections.Generic.List[CommandSuggestion]]::new()
    $input = $context.InputText.Trim()

    try {
      # Get AI predictions from Python backend
      $request = @{
        type          = "predict"
        current_input = $input
        history       = $this.CommandHistory
      } | ConvertTo-Json

      $this.WebSocketClient.SendMessage($request).Wait()
      $response = $this.WebSocketClient.ReceiveMessage().Result | ConvertFrom-Json

      if ($response.type -eq "predictions") {
        foreach ($pred in $response.predictions) {
          $suggestions.Add([CommandSuggestion]::new(
              $pred.command,
              "AI Prediction (Score: $([math]::Round($pred.score, 2)))",
              "AI"
            ))
        }
      }
    } catch {
      Write-Warning "Failed to get AI predictions: $_"

      # Fallback to basic predictions
      foreach ($historicCommand in $this.CommandHistory) {
        if ($historicCommand.StartsWith($input, [StringComparison]::OrdinalIgnoreCase)) {
          $suggestions.Add([CommandSuggestion]::new($historicCommand, "From history", "History"))
        }
      }
    }

    return $suggestions
  }

  [void] RecordCommand([string]$command) {
    if ([string]::IsNullOrWhiteSpace($command)) { return }

    if (-not $this.CommandHistory.Contains($command)) {
      $this.CommandHistory.Add($command)

      # Keep only last 1000 commands
      while ($this.CommandHistory.Count -gt 1000) {
        $this.CommandHistory.RemoveAt(0)
      }

      # Save to file
      try {
        $this.CommandHistory | ConvertTo-Json | Set-Content $this.Settings.HistoryFilePath

        # Send to AI backend
        $request = @{
          type    = "record"
          command = $command
          context = $null  # Could add terminal context here
        } | ConvertTo-Json

        $this.WebSocketClient.SendMessage($request).Wait()
      } catch {
        Write-Warning "Failed to record command: $_"
      }
    }
  }

  [void] Enable() {
    $this.Settings.IsEnabled = $true
    Write-Host "AI Predictor enabled"
  }

  [void] Disable() {
    $this.Settings.IsEnabled = $false
    Write-Host "AI Predictor disabled"
  }
}
#endregion Classes

# Types that will be available to users when they import the module.
$typestoExport = @(
  [CommandSuggestion],
  [CommandPredictor],
  [PredictionContext],
  [PredictionSettings]
)

$TypeAcceleratorsClass = [PsObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
foreach ($Type in $typestoExport) {
  if ($Type.FullName -in $TypeAcceleratorsClass::Get.Keys) {
    $Message = @(
      "Unable to register type accelerator '$($Type.FullName)'"
      'Accelerator already exists.'
    ) -join ' - '

    [System.Management.Automation.ErrorRecord]::new(
      [System.InvalidOperationException]::new($Message),
      'TypeAcceleratorAlreadyExists',
      [System.Management.Automation.ErrorCategory]::InvalidOperation,
      $Type.FullName
    ) | Write-Warning
  }
}

# Add type accelerators for every exportable type.
foreach ($Type in $typestoExport) {
  $TypeAcceleratorsClass::Add($Type.FullName, $Type)
}

# Remove type accelerators when the module is removed.
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
  foreach ($Type in $typestoExport) {
    $TypeAcceleratorsClass::Remove($Type.FullName)
  }
}.GetNewClosure()

$scripts = @();
$Public = Get-ChildItem "$PSScriptRoot/Public" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += Get-ChildItem "$PSScriptRoot/Private" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += $Public

foreach ($file in $scripts) {
  Try {
    if ([string]::IsNullOrWhiteSpace($file.fullname)) { continue }
    . "$($file.fullname)"
  } Catch {
    Write-Warning "Failed to import function $($file.BaseName): $_"
    $host.UI.WriteErrorLine($_)
  }
}

$Param = @{
  Function = $Public.BaseName
  Cmdlet   = '*'
  Alias    = '*'
  Verbose  = $false
}
Export-ModuleMember @Param
