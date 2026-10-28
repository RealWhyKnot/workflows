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
            File    = 'eslint.config.mjs'
            Tracked = '^eslint\.config\.[cm]?[jt]s$'
            Reason  = 'the repo has a second ESLint config'
        }
    )
}
