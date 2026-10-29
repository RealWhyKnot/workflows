@{
    Rules = @(
        @{
            File    = 'prettier.config.mjs'
            Tracked = '^prettier\.config\.[cm]?[jt]s$'
            Reason  = 'the repo has a second Prettier config'
        }
        @{
            File    = 'prettier.config.mjs'
            Tracked = '(^|/)package\.json$'
            Matches = '"prettier"\s*:\s*\{'
            Reason  = 'a package.json has a "prettier" key'
        }
        @{
            File    = 'stylelint.config.mjs'
            Tracked = '^stylelint\.config\.[cm]?[jt]s$'
            Reason  = 'the repo has a second Stylelint config'
        }
        @{
            File    = 'stylelint.config.mjs'
            Tracked = '(^|/)package\.json$'
            Matches = '"stylelint"\s*:\s*\{'
            Reason  = 'a package.json has a "stylelint" key'
        }
    )
}
