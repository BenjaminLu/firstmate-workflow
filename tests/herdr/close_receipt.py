from herdr import *
import threading


class CloseReceipt(unittest.TestCase):
    def test_concurrent_uncertain_writer_cannot_overwrite_closed(self):
        # Pause the successful writer after its read/check, before durable save.
        # Without serialization the uncertain writer also passes its read/check,
        # then saves last. With serialization it waits and sees the closed receipt.
        for successful_source in ('transport', 'pane-child'):
            for initial in (None, {'status': 'retained: uncertain observation'}):
                with self.subTest(source=successful_source, initial=initial), tempfile.TemporaryDirectory() as tmp:
                    attempt = Path(tmp)
                    if initial is not None:
                        m.save(attempt / 'close.json', initial)
                    closed = dict(actor='worker', pane='owned', status='closed', source=successful_source)
                    uncertain = dict(actor='worker', pane='owned', status='retained: uncertain observation',
                                     source='pane-child' if successful_source == 'transport' else 'transport')
                    saving_closed = threading.Event()
                    contender_entered = threading.Event()
                    closed_saved = threading.Event()
                    local = threading.local()
                    real_save, real_flock = m.save, m.fcntl.flock

                    def flock(fd, operation):
                        if getattr(local, 'contender', False):
                            contender_entered.set()
                        return real_flock(fd, operation)

                    def save(path, payload):
                        if payload == closed:
                            saving_closed.set()
                            if not contender_entered.wait(10):
                                raise AssertionError('uncertain writer did not enter')
                            real_save(path, payload)
                            closed_saved.set()
                        else:
                            # Old unlocked code reaches here with a stale decision.
                            contender_entered.set()
                            if not closed_saved.wait(10):
                                raise AssertionError('successful writer did not publish')
                            real_save(path, payload)

                    def contend():
                        local.contender = True
                        return m.record_close(attempt, uncertain)

                    with patch.object(m, 'save', save), patch.object(m.fcntl, 'flock', flock):
                        # Threads are joined before patches or temporary files leave scope.
                        # Separate opens use the real kernel flock, just like the two writers.
                        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                            winner = pool.submit(m.record_close, attempt, closed)
                            self.assertTrue(saving_closed.wait(10), 'successful writer did not enter save')
                            contender = pool.submit(contend)
                            self.assertEqual(closed, winner.result(timeout=15))
                            contender_result = contender.result(timeout=15)
                    self.assertEqual(closed, m.read(attempt / 'close.json'))
                    self.assertEqual(closed, contender_result)

    def test_retention_is_not_promoted_without_successful_close(self):
        with tempfile.TemporaryDirectory() as tmp:
            attempt = Path(tmp)
            retained = dict(status='retained: uncertain observation', source='pane-child')
            self.assertEqual(retained, m.record_close(attempt, retained))
            self.assertEqual(retained, m.read(attempt / 'close.json'))
            closed = dict(status='closed', source='transport', pane='owned', actor='worker')
            self.assertEqual(closed, m.record_close(attempt, closed))
            # Preserve the complete first successful receipt, including its provenance.
            self.assertEqual(closed, m.record_close(attempt, dict(closed, source='pane-child')))
            self.assertEqual(closed, m.read(attempt / 'close.json'))


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]])
