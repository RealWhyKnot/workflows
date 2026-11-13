BEGIN {
  while ((status = (getline entry < ".github/lint/vendored-paths.txt")) > 0) {
    sub(/\r$/, "", entry)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", entry)
    if (entry == "") {
      continue
    }
    if (entry ~ /^\/.*[^\/]$/) {
      files[substr(entry, 2)] = 1
      continue
    }
    sub(/\/*$/, "/", entry)
    if (substr(entry, 1, 1) == "/") {
      roots[++root_count] = substr(entry, 2)
    } else {
      names[++name_count] = "/" entry
    }
  }
  if (status < 0) {
    print ".github/lint/vendored-paths.txt is missing. Run Install-Lint again." > "/dev/stderr"
    is_broken = 1
    exit
  }
}

function report(file, line, message) {
  printf "%s:%d: %s\n", file, line, message
  has_findings = 1
}

function is_vendored(path, position) {
  if (path in files) {
    return 1
  }
  for (position = 1; position <= root_count; position++) {
    if (index(path, roots[position]) == 1) {
      return 1
    }
  }
  for (position = 1; position <= name_count; position++) {
    if (index("/" path, names[position]) > 0) {
      return 1
    }
  }
  return 0
}

function count(text, pattern, copy) {
  copy = text
  return gsub(pattern, "", copy)
}

function check_attribute(text, file, line) {
  if (text ~ /#!?\[[[:space:]]*rustfmt::skip/ || text ~ /#!?\[[[:space:]]*cfg_attr[[:space:]]*\(.*rustfmt::skip/) {
    report(file, line, "remove rustfmt::skip and let rustfmt format it (RS-3)")
  }
}

function check_expect(text, line, message) {
  while (match(text, /\.expect\([[:space:]]*"([^"\\]|\\.)*"[[:space:]]*\)/)) {
    message = substr(text, RSTART, RLENGTH)
    text = substr(text, RSTART + RLENGTH)
    sub(/^\.expect\([[:space:]]*"/, "", message)
    sub(/"[[:space:]]*\)$/, "", message)
    if (split(message, words, /[[:space:]]+/) < 4) {
      report(FILENAME, line, "say in the expect message why the value is always there (RS-8)")
    }
  }
}

function clean_line(text, result, position, tail, char, pair, size) {
  visible = ""
  for (position = 1; position <= length(text); position++) {
    tail = substr(text, position)
    char = substr(tail, 1, 1)
    pair = substr(tail, 1, 2)
    size = 1
    if (block_depth > 0) {
      if (pair == "/*") {
        block_depth++
        size = 2
      } else if (pair == "*/") {
        block_depth--
        size = 2
      }
    } else if (raw_end != "") {
      if (index(tail, raw_end) == 1) {
        size = length(raw_end)
        raw_end = ""
      }
    } else if (in_string) {
      visible = visible char
      if (char == "\\") {
        size = 2
        visible = visible substr(tail, 2, 1)
      } else if (char == "\"") {
        in_string = 0
      }
      result = result sprintf("%*s", size, "")
      position += size - 1
      continue
    } else if (pair == "//") {
      break
    } else if (pair == "/*") {
      block_depth = 1
      size = 2
    } else if (match(tail, /^(br|cr|r)#+"/) || match(tail, /^(br|cr|r)"/)) {
      size = RLENGTH
      raw_end = substr(tail, 1, size)
      sub(/^[bcr]+/, "", raw_end)
      sub(/"$/, "", raw_end)
      raw_end = "\"" raw_end
    } else if (char == "\"") {
      in_string = 1
      visible = visible char
      result = result " "
      continue
    } else if (match(tail, /^'([^'\\]|\\([^u]|u\{[0-9A-Fa-f_]+\}))'/)) {
      size = RLENGTH
    } else {
      result = result char
      visible = visible char
      continue
    }
    result = result sprintf("%*s", size, "")
    visible = visible sprintf("%*s", size, "")
    position += size - 1
  }
  return result
}

function cfg_value(text, kind, body, level, position, start, char, value, result) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", text)
  if (text == "test" || text == "false") {
    return 0
  }
  if (text == "true") {
    return 1
  }
  if (text !~ /^(all|any|not)[[:space:]]*\(/) {
    return -1
  }
  kind = text
  sub(/[[:space:]]*\(.*/, "", kind)
  body = text
  sub(/^[^(]*\(/, "", body)
  sub(/\)[[:space:]]*$/, "", body)
  if (kind == "not") {
    value = cfg_value(body)
    return value < 0 ? -1 : !value
  }
  result = kind == "all"
  start = 1
  for (position = 1; position <= length(body) + 1; position++) {
    char = substr(body, position, 1)
    if (char == "(") {
      level++
    } else if (char == ")") {
      level--
    }
    if ((char == "," && level == 0) || position > length(body)) {
      value = substr(body, start, position - start)
      start = position + 1
      if (value ~ /^[[:space:]]*$/) {
        continue
      }
      value = cfg_value(value)
      if ((kind == "all" && value == 0) || (kind == "any" && value == 1)) {
        return value
      }
      if (value < 0) {
        result = -1
      }
    }
  }
  return result
}

function track_test_item(code, position, char) {
  expect_text = ""
  for (position = 1; position <= length(code); position++) {
    char = substr(code, position, 1)
    expect_text = expect_text (test_depth > 0 || test_pending ? " " : substr(visible, position, 1))
    if (test_depth > 0) {
      test_depth += (char == "{") - (char == "}")
    } else if (test_pending) {
      test_brackets += (char == "[") - (char == "]")
      test_parens += (char == "(") - (char == ")")
      if (test_brackets == 0 && test_parens == 0) {
        if (char == "{") {
          test_pending = 0
          in_test_module = 1
          test_depth = 1
        } else if (char == ";") {
          test_pending = 0
        }
      }
    }
  }
}

function check_line(text, line) {
  if (!is_test_file) {
    check_expect(expect_text, line)
  }
  if (text ~ /(^|[^a-z_])pub[[:space:]]*(\([[:space:]]*(crate|in[[:space:]][^)]*)[[:space:]]*\))?[[:space:]]+(const[[:space:]]+)?(async[[:space:]]+)?unsafe[[:space:]]+(extern[[:space:]]*("[^"]*"[[:space:]]*)?)?fn[[:space:]]/) {
    report(FILENAME, line, "an unsafe fn is private or pub(super); expose a safe fn instead (RS-2)")
  }
  if (text ~ /map_err\([[:space:]]*\|[[:space:]]*[a-z_][a-z0-9_]*[[:space:]]*\|[[:space:]]*[a-z_][a-z0-9_]*\.to_string\(\)[[:space:]]*\)/ || text ~ /map_err\([[:space:]]*\|[^|]*\|[[:space:]]*format!\([[:space:]]*"\{[a-z_0-9]*\}"[[:space:]]*(,[[:space:]]*[a-z_][a-z0-9_]*[[:space:]]*)?\)[[:space:]]*\)/ || text ~ /map_err\([[:space:]]*(std::string::)?ToString::to_string[[:space:]]*\)/) {
    report(FILENAME, line, "add what was being done to the error text (rust.md §3)")
  }
}

FNR == 1 {
  if (attribute != "") {
    check_attribute(attribute, attribute_file, start)
  }
  attribute = ""
  is_vendored_file = is_vendored(FILENAME)
  is_test_file = FILENAME ~ /(^|\/)(benches|examples)\// || FILENAME ~ /(^|\/)([^\/]*_)?tests?(\/|\.rs$)/
  in_test_module = 0
  test_pending = 0
  test_depth = 0
  test_brackets = 0
  test_parens = 0
  block_depth = 0
  in_string = 0
  raw_end = ""
}

is_vendored_file {
  next
}

{
  code = clean_line($0)
  if (attribute == "" && match(code, /#!?\[/)) {
    attribute = substr(code, RSTART)
    attribute_file = FILENAME
    start = FNR
  } else if (attribute != "") {
    attribute = attribute " " code
  }
  if (attribute != "" && (count(attribute, "\\[") <= count(attribute, "\\]") || FNR - start > 30)) {
    check_attribute(attribute, attribute_file, start)
    predicate = attribute
    if (predicate ~ /^#\[[[:space:]]*cfg[[:space:]]*\(/) {
      sub(/^#\[[[:space:]]*cfg[[:space:]]*\(/, "", predicate)
      sub(/\)[[:space:]]*\].*$/, "", predicate)
      if (cfg_value(predicate) == 0) {
        test_pending = 1
        test_brackets = 0
        test_parens = 0
        end = index(code, "]")
        code = sprintf("%*s", end, "") substr(code, end + 1)
      }
    }
    attribute = ""
  }
  track_test_item(code)
  check_line(visible, FNR)
  if (test_depth <= 0) {
    in_test_module = 0
  }
}

END {
  if (is_broken) {
    exit 2
  }
  if (attribute != "") {
    check_attribute(attribute, attribute_file, start)
  }
  exit has_findings
}
