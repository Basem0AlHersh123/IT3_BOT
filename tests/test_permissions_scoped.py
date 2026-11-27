"""Unit tests for ADR-0003 Scoped Role Grants & Scope Tree ancestry in core/permissions.py."""
from __future__ import annotations

import unittest

from core.permissions import allowed_nodes, can

# Sample Scope Tree:
# College 1 (CSIT)
#  ├── Major 2 (IT)
#  │    └── Cohort 10 (IT3)
#  │         ├── Theory Group 100 (IT3_G1)
#  │         │    ├── Practical Group 1001 (G1)
#  │         │    └── Practical Group 1002 (G2)
#  │         └── Theory Group 101 (IT3_G2)
#  │              └── Practical Group 1011 (G3)
#  └── Major 3 (CS)
#       └── Cohort 20 (CS3)
#            └── Theory Group 200 (CS3_G1)
#                 └── Practical Group 2001 (G1)

NODE_COLLEGE = {"id": 1, "path": [1]}
NODE_MAJOR_IT = {"id": 2, "path": [1, 2]}
NODE_COHORT_IT3 = {"id": 10, "path": [1, 2, 10]}
NODE_IT3_G1 = {"id": 100, "path": [1, 2, 10, 100]}
NODE_IT3_G1_P1 = {"id": 1001, "path": [1, 2, 10, 100, 1001]}
NODE_IT3_G2 = {"id": 101, "path": [1, 2, 10, 101]}
NODE_COHORT_CS3 = {"id": 20, "path": [1, 3, 20]}
NODE_CS3_G1 = {"id": 200, "path": [1, 3, 20, 200]}
NODE_CS3_G1_P1 = {"id": 2001, "path": [1, 3, 20, 200, 2001]}

ALL_THEORY_NODES = [NODE_IT3_G1, NODE_IT3_G2, NODE_CS3_G1]


class ScopedPermissionInheritanceTests(unittest.TestCase):
    def test_developer_matches_every_node(self) -> None:
        perms = [{"k": "roles.manage", "s": "any", "n": None, "c": None}]
        for node in (NODE_COLLEGE, NODE_COHORT_IT3, NODE_IT3_G1_P1, NODE_CS3_G1_P1):
            self.assertTrue(can(perms, "roles.manage", scope_node_id=node["id"], target_path=node["path"]))

    def test_college_admin_inherits_down_to_all_majors_cohorts_and_groups(self) -> None:
        perms = [{"k": "assignments.create", "s": "college", "n": 1, "c": None}]
        for node in (NODE_COLLEGE, NODE_MAJOR_IT, NODE_COHORT_IT3, NODE_IT3_G1, NODE_IT3_G1_P1, NODE_CS3_G1_P1):
            self.assertTrue(can(perms, "assignments.create", scope_node_id=node["id"], target_path=node["path"]))
        # Does not match another college (id=99)
        other_college_group = {"id": 9900, "path": [99, 990, 9900]}
        self.assertFalse(can(perms, "assignments.create", scope_node_id=9900, target_path=other_college_group["path"]))

    def test_major_admin_inherits_across_all_cohorts_in_own_major_only(self) -> None:
        perms = [{"k": "roles.manage", "s": "major", "n": 2, "c": None}]
        # Can manage Major IT (2), IT3 Cohort (10), and all IT3 groups
        for node in (NODE_MAJOR_IT, NODE_COHORT_IT3, NODE_IT3_G1, NODE_IT3_G1_P1, NODE_IT3_G2):
            self.assertTrue(can(perms, "roles.manage", scope_node_id=node["id"], target_path=node["path"]))
        # Cannot manage parent College (1) or sibling Major CS / CS3 Cohort (20)
        for node in (NODE_COLLEGE, NODE_COHORT_CS3, NODE_CS3_G1, NODE_CS3_G1_P1):
            self.assertFalse(can(perms, "roles.manage", scope_node_id=node["id"], target_path=node["path"]))

    def test_cohort_admin_isolated_to_own_cohort_subtree(self) -> None:
        perms = [{"k": "students.manage", "s": "cohort", "n": 10, "c": None}]
        # Can manage IT3 cohort and its theory/practical groups
        for node in (NODE_COHORT_IT3, NODE_IT3_G1, NODE_IT3_G1_P1, NODE_IT3_G2):
            self.assertTrue(can(perms, "students.manage", scope_node_id=node["id"], target_path=node["path"]))
        # Cannot manage parent Major/College or sibling Cohort CS3
        for node in (NODE_COLLEGE, NODE_MAJOR_IT, NODE_COHORT_CS3, NODE_CS3_G1, NODE_CS3_G1_P1):
            self.assertFalse(can(perms, "students.manage", scope_node_id=node["id"], target_path=node["path"]))

    def test_group_rep_isolated_to_own_group_and_descendants(self) -> None:
        perms = [{"k": "attendance.session", "s": "group", "n": 100, "c": None}]
        self.assertTrue(can(perms, "attendance.session", scope_node_id=100, target_path=NODE_IT3_G1["path"]))
        self.assertTrue(can(perms, "attendance.session", scope_node_id=1001, target_path=NODE_IT3_G1_P1["path"]))
        self.assertFalse(can(perms, "attendance.session", scope_node_id=101, target_path=NODE_IT3_G2["path"]))
        self.assertFalse(can(perms, "attendance.session", scope_node_id=10, target_path=NODE_COHORT_IT3["path"]))

    def test_multi_grant_user_aggregates_allowed_nodes(self) -> None:
        perms = [
            {"k": "assignments.create", "s": "group", "n": 100, "c": None},
            {"k": "assignments.create", "s": "group", "n": 200, "c": None},
        ]
        self.assertEqual(allowed_nodes(perms, "assignments.create", ALL_THEORY_NODES), [100, 200])

    def test_delegate_absent_condition_honored_with_scope_nodes(self) -> None:
        perms = [{"k": "attendance.session", "s": "group", "n": 100, "c": "delegate_absent"}]
        self.assertFalse(can(perms, "attendance.session", scope_node_id=100, target_path=NODE_IT3_G1["path"]))
        self.assertTrue(
            can(perms, "attendance.session", scope_node_id=100, target_path=NODE_IT3_G1["path"], delegate_absent=True)
        )
        self.assertFalse(
            can(perms, "attendance.session", scope_node_id=101, target_path=NODE_IT3_G2["path"], delegate_absent=True)
        )

    def test_no_target_returns_true_for_ui_visibility(self) -> None:
        perms = [{"k": "roles.manage", "s": "cohort", "n": 10, "c": None}]
        self.assertTrue(can(perms, "roles.manage"))
        self.assertFalse(can(perms, "scopes.manage"))

    def test_empty_perms_denies_everything(self) -> None:
        self.assertFalse(can([], "files.view", scope_node_id=10, target_path=NODE_COHORT_IT3["path"]))
        self.assertEqual(allowed_nodes([], "assignments.create", ALL_THEORY_NODES), [])


if __name__ == "__main__":
    unittest.main()
