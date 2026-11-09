## test_hitl.py ViewTests: status and show on the coordinator fixture.

import std/strutils
import fixtures

setUp()

block test_status_lists_agents_with_branch:  # test_hitl.py::ViewTests::test_status_lists_agents_with_branch
  let s = cli(["status"]).output
  check "Fix the field default crash" in s, "status names the fixer"
  check "fix/f7 +2" in s, "no remote: the base commit counts too"

block test_show_prints_the_final_report:  # test_hitl.py::ViewTests::test_show_prints_the_final_report
  let s = cli(["show", "a1111111"]).output
  check "sem: reject the bad default" in s, "show lists the fixer's commit"
  check "The default is **typed**" in s, "show prints the final report"

tearDown()
