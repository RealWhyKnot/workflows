@{
    Rules = @(
        @{ File = 'Directory.Build.props'; Tracked = '(^|/)ProjectSettings/ProjectVersion\.txt$|\.asmdef$'; Skip = $true; Reason = 'this is a Unity project or package' }
        @{ File = 'Directory.Build.targets'; Tracked = '(^|/)ProjectSettings/ProjectVersion\.txt$|\.asmdef$'; Skip = $true; Reason = 'this is a Unity project or package' }
        @{ File = 'Directory.Build.props'; When = 'package.json'; Matches = '"unity"\s*:'; Skip = $true; Reason = 'this is a Unity package' }
        @{ File = 'Directory.Build.targets'; When = 'package.json'; Matches = '"unity"\s*:'; Skip = $true; Reason = 'this is a Unity package' }
        @{ File = '.editorconfig'; Tracked = '(^|/)ProjectSettings/ProjectVersion\.txt$|\.asmdef$'; Use = 'merge/unity/.editorconfig'; Reason = 'this is a Unity project or package' }
        @{ File = '.editorconfig'; When = 'package.json'; Matches = '"unity"\s*:'; Use = 'merge/unity/.editorconfig'; Reason = 'this is a Unity package' }
    )
}
