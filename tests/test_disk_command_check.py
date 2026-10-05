# SPDX-License-Identifier: Apache-2.0
#
# .github/scripts/check-disk-commands.py: CI's "no step runs mkfs" check. A broken check reads
# exactly like "no hits", so its heredoc reading is tested here on small scripts.

import os
import tempfile
import unittest

from _load import load

CK = load(".github/scripts/check-disk-commands.py", "check_disk_commands")


class DiskCommandCheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def hits(self, text, name="step.sh"):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w") as fh:
            fh.write(text)
        return [h.split(":", 2)[1] for h in CK.check(path)]

    def test_plain_commands_are_caught(self):
        for cmd in ("mkfs.ext4 /dev/sda1", "mke2fs /dev/sda1", "mkswap /dev/sda2", "wipefs -a x",
                    "sfdisk /dev/sda", "gdisk /dev/sda", "cfdisk", "blkdiscard /dev/sda",
                    "dd if=/dev/zero of=/dev/sda bs=1M", "cryptsetup -q luksFormat /dev/sda1",
                    'run "mkfs.ext4" -L x /dev/sda1'):
            self.assertEqual(self.hits(f"#!/bin/bash\n{cmd}\n"), ["2"], cmd)

    def test_the_wider_list_is_caught(self):
        for cmd in ("mkdosfs /dev/sda1", "mkntfs -f /dev/sda1", "mkexfatfs /dev/sda1",
                    "systemd-repart --dry-run=no /dev/sda", "shred -n1 /dev/sda",
                    "pvcreate /dev/sda1", "vgcreate vg /dev/sda1", "lvcreate -L1G vg",
                    "mdadm --create /dev/md0 --level=1", "mdadm -C /dev/md0",
                    'dd if=/dev/zero of="/dev/sda"', "dd if=x of=$DEV bs=1M",
                    "dd if=x of=\"$DEV\"", "cat img > /dev/sda", "printf x >>/dev/mmcblk0",
                    "cat x >| '/dev/nvme0n1'", "cat x > /dev/disk/by-id/usb-x"):
            self.assertEqual(self.hits(f"#!/bin/bash\n{cmd}\n"), ["2"], cmd)

    def test_harmless_neighbors_pass(self):
        text = ("#!/bin/bash\necho x >/dev/null\necho x >&2\ndd if=a of=b.img\n"
                "mdadm --detail /dev/md0\ncat x > /dev/stderr\n")
        self.assertEqual(self.hits(text), [])

    def test_words_that_only_contain_a_command_pass(self):
        self.assertEqual(self.hits("#!/bin/bash\nsgdisk_help=1\nmy-mkfs-notes\n# mkfs here\n"), [])

    def test_cat_heredoc_text_is_skipped_and_the_check_resumes_after_it(self):
        text = "#!/bin/bash\ncat >&2 <<EOF\n  sudo mkfs.ext4 -L x /dev/sdX1\nEOF\nmkfs.ext4 /dev/sda1\n"
        self.assertEqual(self.hits(text), ["5"])

    def test_a_hyphenated_or_dotted_delimiter_does_not_swallow_the_file(self):
        for op in ("cat <<END-OF-HELP", "cat <<EOF.x", "cat <<'END-OF-HELP'", 'cat <<"EOF.x"',
                   "cat <<-END-OF-HELP", "cat <<\\END-OF-HELP"):
            delim = op.split("<<", 1)[1].lstrip("-").strip("'\"\\")
            text = f"#!/bin/bash\n{op}\n  sudo mkfs.ext4 /dev/sdX1\n{delim}\nmkfs.ext4 /dev/sda1\n"
            self.assertEqual(self.hits(text), ["5"], op)

    def test_a_quoted_delimiter_with_a_space_is_one_word(self):
        text = "#!/bin/bash\ncat <<'END OF'\nmkfs text\nEND OF\nwipefs -a /dev/sda\n"
        self.assertEqual(self.hits(text), ["5"])

    def test_cat_piped_into_a_shell_is_checked(self):
        self.assertEqual(self.hits("#!/bin/bash\ncat <<EOF | bash\nmkfs.ext4 /dev/sda1\nEOF\n"),
                         ["3"])
        self.assertEqual(self.hits("#!/bin/bash\ncat <<'EOF' | sudo sh\nwipefs -a x\nEOF\n"),
                         ["3"])

    def test_an_unquoted_cat_body_line_that_runs_a_command_is_checked(self):
        text = ("#!/bin/bash\ncat <<EOF\nsee mkfs.ext4 in the guide\n$(mkfs.ext4 /dev/sda1)\n"
                "`wipefs -a /dev/sda`\nEOF\n")
        self.assertEqual(self.hits(text), ["4", "5"])
        # Quoted: the body is literal, nothing in it runs.
        text = "#!/bin/bash\ncat <<'EOF'\n$(mkfs.ext4 /dev/sda1)\nEOF\n"
        self.assertEqual(self.hits(text), [])

    def test_a_heredoc_fed_to_a_shell_or_python_is_checked(self):
        self.assertEqual(self.hits("#!/bin/bash\nbash <<'EOF'\nmkfs.ext4 /dev/sda1\nEOF\n"), ["3"])
        text = "#!/bin/bash\nout=$(python3 - <<'PY'\nsubprocess.run(['wipefs', '-a'])\nPY\n)\n"
        self.assertEqual(self.hits(text), ["3"])

    def test_a_stray_shift_or_quoted_marker_does_not_swallow_the_file(self):
        for stray in ("(( x = 1 << shift ))", "y=$(( 1 << bits ))", 'echo "see <<EOF here"',
                      "echo 'a <<END'", "grep x <<<\"$v\""):
            text = f"#!/bin/bash\n{stray}\nmkfs.ext4 /dev/sda1\n"
            self.assertEqual(self.hits(text), ["3"], stray)

    def test_two_heredocs_on_one_line_end_at_their_own_terminators(self):
        text = ("#!/bin/bash\ncat <<A; bash <<B\ntext mkfs\nA\nwipefs -a /dev/sda\nB\n"
                "mkswap /dev/sdb\n")
        self.assertEqual(self.hits(text), ["5", "7"])

    def test_a_dash_heredoc_ends_at_a_tab_indented_terminator(self):
        text = "#!/bin/bash\ncat <<-EOF\n\tmkfs text\n\tEOF\nparted /dev/sda\n"
        self.assertEqual(self.hits(text), ["5"])

    def test_python_shifts_are_not_heredocs(self):
        text = "#!/usr/bin/env python3\nx = y << shift\nos.system('mkfs.ext4 /dev/sda1')\n"
        self.assertEqual(self.hits(text, "tool"), ["3"])

    def test_an_undecodable_file_raises_rather_than_passes(self):
        path = os.path.join(self.tmp.name, "bad.sh")
        with open(path, "wb") as fh:
            fh.write(b"#!/bin/bash\n\xff\xfe mkfs\n")
        with self.assertRaises(UnicodeDecodeError):
            CK.check(path)


if __name__ == "__main__":
    unittest.main()
