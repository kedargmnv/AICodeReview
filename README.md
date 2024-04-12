# AI Code Review

This repository contains a PowerShell script (`AICodeReview.ps1`) that uses OpenAI's GPT-4 model to perform an AI-based code review on a GitLab merge request.

## How it works

The script performs the following steps:

1. Checks for existing comments in the merge request that contain the phrase "Code Analysis by AI". If such a comment already exists, the script skips the code review.

2. Retrieves the changes made in the merge request. It groups these changes by file and ignores any files with extensions listed in the `.aiignore` file.

3. For each file, it invokes the OpenAI API to analyze the changes and generate a code review. The review is split into chunks of 1000 characters.

4. Posts each chunk as a separate comment on the merge request.

## Usage

To use the script, you need to provide the following parameters:

- `GitLabToken`: Your GitLab API token.
- `GitLabApiUrl`: The URL of your GitLab API.
- `RepositoryId`: The ID of your GitLab repository.
- `OpenAiApiKey`: Your OpenAI API key.
- `Model`: The OpenAI model to use for the code review.

You can run the script in PowerShell with the following command:

```powershell
.\AICodeReview.ps1 -GitLabToken "your-gitlab-token" -gitLabApiUrl "your-gitlab-api-url" -repositoryId "your-repository-id" -openAiApiKey "your-openai-api-key"
