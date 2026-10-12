// Gate 4 parses these same named assertion lines from bash and browser suites.
import type { Reporter, Suite, TestCase, TestResult } from '@playwright/test/reporter';

export default class FailFirstReporter implements Reporter {
  private suite!: Suite;
  onBegin(_config: unknown, suite: Suite) { this.suite = suite; }
  onTestEnd(_test: TestCase, result: TestResult) {
    for (const error of result.errors) process.stderr.write(`${error.message || error.value}\n`);
  }
  onError(error: {message?: string; value?: string}) {
    process.stderr.write(`${error.message || error.value}\n`);
  }
  onEnd() {
    for (const test of this.suite.allTests()) {
      // Skipped/interrupted tests never masquerade as passing assertions.
      const ok = test.results.length > 0 && test.results.every(result => result.status === 'passed');
      process.stdout.write(`    ${test.title.replace(/[\r\n]/g, ' ')} ${ok ? 'ok' : 'FAIL'}\n`);
    }
  }
}
