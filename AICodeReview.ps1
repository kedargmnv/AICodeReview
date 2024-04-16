param (
    [string]$GitLabToken,
    [string]$GitLabApiUrl,
    [string]$RepositoryId,
    [string]$OpenAiApiKey,
    [string]$Model = "gpt-4-1106-preview"
)

$SkipExtensions = Get-Content "..\..\.aiignore"

function Get-ExistingComments {
    param (
        [string]$GitLabToken,
        [string]$GitLabApiUrl,
        [string]$RepositoryId,
        [string]$MergeRequestId
    )

    try {
        Write-Host "Checking for existing comments..."
        $Uri = "$GitLabApiUrl/$RepositoryId/merge_requests/$MergeRequestId/notes"

        $Response = Invoke-RestMethod -Uri $Uri -Headers @{
            "PRIVATE-TOKEN" = $GitLabToken
        } -Method Get

        if ($null -eq $Response) {
            Write-Host "No comments in the response from GitLab API."
            return $false
        }

        $ExistingComment = $Response | Where-Object { $_.body -like "*Code Analysis by AI*" }

        if ($ExistingComment) {
            Write-Host "A comment containing 'Code Analysis by AI' already exists."
            return $true
        } else {
            Write-Host "No existing comment contains 'Code Analysis by AI'."
            return $false
        }
    } catch {
        Write-Host "Error in Check-ExistingComments : $_"
    }
}

function Split-String {
    param (
        [string]$String,
        [int]$ChunkSize
    )

    $Chunks = @()
    $CurrentChunk = ""
    $Lines = $String -split "`n"

    foreach ($Line in $Lines) {
        if (($CurrentChunk.Length + $Line.Length) -le $ChunkSize) {
            $CurrentChunk += $Line + "`n"
        } else {
            $Chunks += $CurrentChunk
            $CurrentChunk = $Line + "`n"
        }
    }

    if ($CurrentChunk.Length -gt 0) {
        $Chunks += $CurrentChunk
    }

    return $Chunks
}

function Get-MergeRequestChanges {
    param (
        [string]$GitLabToken,
        [string]$GitLabApiUrl,
        [string]$RepositoryId,
        [string]$MergeRequestId
    )

    try {
        Write-Host "Getting merge request changes..."
        $Uri = "$GitLabApiUrl/$RepositoryId/merge_requests/$MergeRequestId/changes"

        $Response = Invoke-RestMethod -Uri $Uri -Headers @{
            "PRIVATE-TOKEN" = $GitLabToken
        } -Method Get

        if ($null -eq $Response.changes) {
            Write-Host "No changes in the response from GitLab API."
            return $null
        }

        # Group diffs by file path
        $GroupedChanges = $Response.changes | Group-Object -Property old_path

        $Changes = $GroupedChanges | ForEach-Object {
            New-Object PSObject -Property @{
                FileName = $_.Name
                Changes = ($_.Group | ForEach-Object { $_.diff }) -join "`n"
                Extension = [System.IO.Path]::GetExtension($_.Name)
            }
        }

        Write-Host "Successfully retrieved merge request changes."
        return $Changes
    } catch {
        Write-Host "Error in Get-MergeRequestChanges : $_"
    }
}

function Invoke-OpenAiCodeAnalysis {
    param (
        [string]$OpenAiApiKey,
        [string]$CodeChanges,
        [string]$Model
    )

    try {
        Write-Host "Invoking OpenAI code analysis..."
        $Prompt = @"
As an AI code reviewer, your role is to analyze the changes in a Merge Request (MR) within a software development project. You will provide feedback on potential bugs and critical issues. The changes in the MR are provided in the standard git diff (unified diff) format. 

Your responsibilities include:
                
        - Analyzing only the lines of code that have been added, edited, or deleted in the MR. For example, in a git diff, these would be the lines starting with a '+' or '-'.
        ```diff
        - old line of code
        + new line of code
        ```
        - Ignoring any code that hasn't been modified. In a git diff, these would be the lines starting with a ' ' (space).
        ```diff
            unchanged line of code
        ```
        - Avoiding repetition in your reviews if the line of code is correct. For example, if the same line of code appears multiple times in the diff, you should only comment on it once.
        - Overlooking the absence of a new line at the end of all files. This is typically represented in a git diff as '\ No newline at end of file'.
        - Using bullet points for clarity if you have multiple comments.
        ```markdown
        - Comment 1
        - Comment 2
        ```
        - Leveraging Markdown to format your feedback effectively. For example, you can use backticks to format code snippets.
        ```markdown
        `code snippet`
        ```
        - Writing 'EMPTY_CODE_REVIEW' if there are no bugs or critical issues identified.
        - Refraining from writing 'EMPTY_CODE_REVIEW' if there are bugs or critical issues.

Here are the code changes:

$CodeChanges
"@

        $Body = @{
            model = $Model
            messages = @(
                @{
                    role = "system"
                    content = "As as AI assistant, your role is to provide  a detailed code review. Analyze the provided code changes, identify potential issues, suggest improvements, and adhere to best coding practices. Your analysis should be through and consider all aspects of code, including syntax, logic, efficiency and style."
                },
                @{
                    role = "user"
                    content = $Prompt
                }
            )
        } | ConvertTo-Json

        $Response = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" -Headers @{
            "Authorization" = "Bearer $OpenAiApiKey"
        } -Method Post -ContentType "application/json" -Body $Body

        if ($null -eq $Response.choices) {
            Write-Host "No choices in the response from OpenAI API."
            return $null
        }

        $AnalysisChunks = $Response.choices[0].message.content -split "(?<=\.\s)" 

        Write-Host "Successfully invoked OpenAI code analysis."
        return $AnalysisChunks
    } catch {
        Write-Host "Error in Invoke-OpenAiCodeAnalysis : $_"
    }
}

function PostCommentToMergeRequest {
    param (
        [string]$GitLabToken,
        [string]$GitLabApiUrl,
        [string]$RepositoryId,
        [string]$MergeRequestId,
        [string]$Comment
    )

    try {
        Write-Host "Posting comment to merge request..."
        $Uri = "$GitLabApiUrl/$RepositoryId/merge_requests/$MergeRequestId/notes"
        $Body = @{
            body = $Comment
        } | ConvertTo-Json

        Invoke-RestMethod -Uri $Uri -Headers @{
            "PRIVATE-TOKEN" = $GitLabToken
        } -Method Post -ContentType "application/json" -Body $Body

        Write-Host "Successfully posted comment to merge request."
    } catch {
        Write-Host "Error in PostCommentToMergeRequest : $_"
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    Write-Host "Starting main script..."
    $MergeRequestId = $env:CI_MERGE_REQUEST_IID
    Write-Host "MergeRequest is : $MergeRequestId"

    $HasExistingComments = Get-ExistingComments -GitLabToken $GitLabToken -GitLabApiUrl $GitLabApiUrl -RepositoryId $RepositoryId -MergeRequestId $MergeRequestId

    if ($HasExistingComments) {
        Write-Host "Skipping code review due to existing 'Code Analysis by AI' comment."
        return
    }

    $Changes = Get-MergeRequestChanges -GitLabToken $GitLabToken -GitLabApiUrl $GitLabApiUrl -RepositoryId $RepositoryId -MergeRequestId $MergeRequestId

    if ($null -ne $Changes) {
        $LastFileName = $null

        foreach ($Change in $Changes) {

            if ($SkipExtensions -contains $Change.Extension) {
                Write-Host "Skipping file $($Change.FileName) because it's listed in the .aiignore file."
                continue
            }

            $AnalysisChunks = Invoke-OpenAiCodeAnalysis -OpenAiApiKey $OpenAiApiKey -CodeChanges $Change.Changes -Model $Model
            $AnalysisChunks = Split-String -String $AnalysisChunks -ChunkSize 1000

            if ($null -ne $AnalysisChunks) {
                foreach ($AnalysisChunk in $AnalysisChunks) {
                    if ($Change.FileName -ne $LastFileName) {
                        $Comment = "File: $($Change.FileName)`nCode Analysis by AI (Exercise caution, it may provide inaccurate results):`n$AnalysisChunk"
                        Write-Host "File: $($Change.FileName)"
                        $LastFileName = $Change.FileName
                    } else {
                        $Comment = "Code Analysis by AI (Exercise caution, it may provide inaccurate results):`n$AnalysisChunk"
                    }

                    if (![string]::IsNullOrWhiteSpace($Comment)) {
                        PostCommentToMergeRequest -GitLabToken $GitLabToken -GitLabApiUrl $GitLabApiUrl -RepositoryId $RepositoryId -MergeRequestId $MergeRequestId -Comment $Comment                        
                    }
                }
            }
        }
    }
    Write-Host "Finished main script."
} catch {
    Write-Host "Error in main script : $_"
}
