@{
    Merge = @(
        @{ File = 'workspace-lints.toml'; Into = 'Cargo.toml'; Nested = $true }
    )
}
