import unittest

from ovb_rc003 import identity


class SelectSingleCandidateTests(unittest.TestCase):
    def test_selects_sole_matching_candidate_by_name(self):
        candidates = [identity.RC003Candidate(name="MI RC", hardware_match=False)]
        chosen = identity.select_single_candidate(candidates)
        self.assertEqual(chosen.name, "MI RC")

    def test_name_matching_is_case_and_whitespace_insensitive(self):
        candidates = [identity.RC003Candidate(name="  xiaomi bluetooth REMOTE 2 pro  ", hardware_match=False)]
        chosen = identity.select_single_candidate(candidates)
        self.assertEqual(chosen.name.strip().lower(), "xiaomi bluetooth remote 2 pro")

    def test_hardware_match_counts_even_with_unrelated_name(self):
        candidates = [identity.RC003Candidate(name="Unknown Device", hardware_match=True)]
        chosen = identity.select_single_candidate(candidates)
        self.assertTrue(chosen.hardware_match)

    def test_no_candidate_raises_not_found(self):
        candidates = [identity.RC003Candidate(name="Some Other Remote", hardware_match=False)]
        with self.assertRaises(identity.NoCandidateFoundError):
            identity.select_single_candidate(candidates)

    def test_empty_list_raises_not_found(self):
        with self.assertRaises(identity.NoCandidateFoundError):
            identity.select_single_candidate([])

    def test_multiple_qualifying_candidates_fail_closed(self):
        candidates = [
            identity.RC003Candidate(name="MI RC", hardware_match=False),
            identity.RC003Candidate(name="MI RC", hardware_match=False),
        ]
        with self.assertRaises(identity.AmbiguousCandidateError) as ctx:
            identity.select_single_candidate(candidates)
        self.assertEqual(ctx.exception.count, 2)

    def test_multiple_candidates_with_different_names_still_fail_closed(self):
        candidates = [
            identity.RC003Candidate(name="MI RC", hardware_match=False),
            identity.RC003Candidate(name="unrelated", hardware_match=True),
        ]
        with self.assertRaises(identity.AmbiguousCandidateError):
            identity.select_single_candidate(candidates)

    def test_non_matching_candidates_are_ignored_when_one_real_match_exists(self):
        candidates = [
            identity.RC003Candidate(name="Some Other Remote", hardware_match=False),
            identity.RC003Candidate(name="MI RC", hardware_match=False),
        ]
        chosen = identity.select_single_candidate(candidates)
        self.assertEqual(chosen.name, "MI RC")


if __name__ == "__main__":
    unittest.main()
