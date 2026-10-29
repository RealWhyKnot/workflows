@{
    Rules = @(
        @{
            File    = 'ruff.toml'
            When    = 'pyproject.toml'
            Matches = '(?m)^\[tool\.ruff'
            Reason  = 'pyproject.toml has [tool.ruff]'
        }
        @{ File = 'ruff.toml'; When = '.ruff.toml'; Reason = '.ruff.toml exists' }
        @{
            File    = 'pyrightconfig.json'
            When    = 'pyproject.toml'
            Matches = '(?m)^\[tool\.pyright'
            Reason  = 'pyproject.toml has [tool.pyright]'
        }
        @{
            File    = '.github/lint/selftest/__init__.py'
            Tracked = '.'
            Skip    = $true
            Reason  = 'selftest only tests pystyle.py in the workflows repo'
        }
        @{
            File    = '.github/lint/selftest/test_pystyle.py'
            Tracked = '.'
            Skip    = $true
            Reason  = 'selftest only tests pystyle.py in the workflows repo'
        }
    )
}
