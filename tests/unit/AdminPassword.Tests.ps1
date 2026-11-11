BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
}

Describe 'AdminPassword' -Tag 'Unit' {
    Context 'Get-AdminLoginCandidates' {
        It 'puts a set password before the seeded one' {
            $candidates = Get-AdminLoginCandidates -AdminPassword 's3cret'
            $candidates | Should -HaveCount 2
            $candidates[0] | Should -BeExactly 's3cret'
            $candidates[1] | Should -BeExactly 'store'
        }

        It 'returns only the seeded password for an empty one' {
            $candidates = Get-AdminLoginCandidates -AdminPassword ''
            $candidates | Should -HaveCount 1
            $candidates[0] | Should -BeExactly 'store'
        }

        It 'returns only the seeded password when no value is given' {
            $candidates = Get-AdminLoginCandidates
            $candidates | Should -HaveCount 1
            $candidates[0] | Should -BeExactly 'store'
        }

        It 'does not repeat the seeded password' {
            $candidates = Get-AdminLoginCandidates -AdminPassword 'store'
            $candidates | Should -HaveCount 1
            $candidates[0] | Should -BeExactly 'store'
        }
    }

    Context 'Get-AdminToken' {
        It 'falls back to store' {
            Mock Get-AuthToken { $null } -ParameterFilter { $Password -ceq 's3cret' }
            Mock Get-AuthToken { 'tok' } -ParameterFilter { $Password -ceq 'store' }

            Get-AdminToken -ApiUrl 'http://localhost:8090' -AdminPassword 's3cret' | Should -BeExactly 'tok'

            Should -Invoke Get-AuthToken -Times 1 -Exactly -ParameterFilter {
                $Password -ceq 's3cret' -and $Username -ceq 'admin' -and $AppAuthUrl -ceq 'http://localhost:8090/connect/token'
            }
        }

        It 'stops at the first candidate that works' {
            Mock Get-AuthToken { 'first' }

            Get-AdminToken -ApiUrl 'http://localhost:8090' -AdminPassword 's3cret' | Should -BeExactly 'first'

            Should -Invoke Get-AuthToken -Times 1 -Exactly
        }

        It 'returns null when no candidate works' {
            Mock Get-AuthToken { $null }

            Get-AdminToken -ApiUrl 'http://localhost:8090' -AdminPassword 's3cret' | Should -BeNullOrEmpty

            Should -Invoke Get-AuthToken -Times 2 -Exactly
        }

        It 'sends one sign-in request per candidate and never retries a refusal' {
            Mock Invoke-WebRequest { throw 'invalid_grant' } -ParameterFilter { $Body.password -ceq 's3cret' }
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = '{"access_token":"tok"}' } } -ParameterFilter { $Body.password -ceq 'store' }

            Get-AdminToken -ApiUrl 'http://localhost:8090' -AdminPassword 's3cret' | Should -BeExactly 'tok'

            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Body.password -ceq 's3cret' }
            Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $MaximumRetryCount -gt 0 }
        }
    }

    Context 'Get-AuthToken' {
        It 'returns null when the request fails' {
            Mock Invoke-WebRequest { throw 'connection refused' }

            Get-AuthToken -AppAuthUrl 'http://localhost:8090/connect/token' -Username 'admin' -Password 'x' | Should -BeNullOrEmpty
        }

        It 'returns null when the response has no access token' {
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = '{"error":"invalid_grant"}' } }

            Get-AuthToken -AppAuthUrl 'http://localhost:8090/connect/token' -Username 'admin' -Password 'x' | Should -BeNullOrEmpty
        }

        It 'returns the access token' {
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = '{"access_token":"abc"}' } }

            Get-AuthToken -AppAuthUrl 'http://localhost:8090/connect/token' -Username 'admin' -Password 'x' | Should -BeExactly 'abc'
        }
    }

    Context 'Set-AdminPassword' {
        It 'posts the reset' {
            Mock Invoke-RestMethod { [pscustomobject]@{ succeeded = $true } }

            Set-AdminPassword -ApiUrl 'http://localhost:8090' -Token 'tok' -NewPassword 'n3w' | Should -BeTrue

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -ceq 'http://localhost:8090/api/platform/security/users/admin/resetpassword' -and
                $Method -eq 'Post' -and
                $Headers.Authorization -ceq 'Bearer tok' -and
                ($Body | ConvertFrom-Json).newPassword -ceq 'n3w' -and
                ($Body | ConvertFrom-Json).forcePasswordChangeOnNextSignIn -eq $false
            }
        }

        It 'returns false when the platform rejects the password' {
            Mock Invoke-RestMethod { [pscustomobject]@{ succeeded = $false; errors = @('too weak') } }
            Mock Write-Warning {}

            Set-AdminPassword -ApiUrl 'http://localhost:8090' -Token 'tok' -NewPassword 'n3w' | Should -BeFalse
        }

        It 'returns false when the request fails' {
            Mock Invoke-RestMethod { throw 'unauthorized' }
            Mock Write-Warning {}

            Set-AdminPassword -ApiUrl 'http://localhost:8090' -Token 'tok' -NewPassword 'n3w' | Should -BeFalse
        }
    }

    Context 'Watch-Url-Up' {
        BeforeEach {
            Mock Start-Sleep {}
            Mock Write-Host {}
        }

        It 'returns false on timeout and calls OnFailureLog' {
            Mock Invoke-WebRequest { throw 'connection refused' }
            $script:logCalls = 0

            $result = Watch-Url-Up -ApiUrl 'http://localhost:8090' -TimeoutMinutes 1 -RetrySeconds 15 -WaitSeconds 0 -OnFailureLog { $script:logCalls++ }

            $result | Should -BeFalse
            $script:logCalls | Should -BeGreaterThan 0
            Should -Invoke Invoke-WebRequest -Times 4 -Exactly
        }

        It 'returns only a bool when OnFailureLog writes output' {
            Mock Invoke-WebRequest { throw 'connection refused' }

            $result = @(Watch-Url-Up -ApiUrl 'http://localhost:8090' -TimeoutMinutes 1 -RetrySeconds 30 -WaitSeconds 0 -OnFailureLog { 'log line' })

            $result | Should -HaveCount 1
            $result[0] | Should -BeFalse
        }

        It 'returns true once the platform answers 200' {
            $script:attempts = 0
            Mock Invoke-WebRequest {
                $script:attempts++
                if ($script:attempts -lt 2) { throw 'connection refused' }
                [pscustomobject]@{ StatusCode = 200 }
            }

            Watch-Url-Up -ApiUrl 'http://localhost:8090' -TimeoutMinutes 1 -RetrySeconds 15 -WaitSeconds 0 | Should -BeTrue

            Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { $SkipCertificateCheck }
        }

        It 'gives up after the timeout when the answer is never 200' {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 204 } }

            Watch-Url-Up -ApiUrl 'http://localhost:8090' -TimeoutMinutes 1 -RetrySeconds 30 -WaitSeconds 0 | Should -BeFalse

            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        }
    }
}
