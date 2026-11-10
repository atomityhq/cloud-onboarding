// Checks that the released template (atomity.yaml) can be imported into a CDK app with
// CfnInclude, which is how CDK users deploy it. Run with: npm test
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { App, Stack } = require('aws-cdk-lib');
const { CfnInclude } = require('aws-cdk-lib/cloudformation-include');
const { Template } = require('aws-cdk-lib/assertions');

const TEMPLATE = path.join(__dirname, '..', 'atomity.yaml');
const PERMISSION = path.join(__dirname, '..', '..', 'policies', 'permission.json');
const ACCOUNT = '123456789012';

// CDK prints its template validation warnings while synthesizing. Capture them so they can be
// asserted on and do not clutter the test output. Node routes console.* through
// process.stderr.write, but Bun does not, so both are intercepted. In a terminal CDK colors
// its output (so a line starts with an escape code, not "WARNING"), hence the stripping.
const ANSI = /\u001b\[[0-9;]*m/g;
function capture(fn) {
  const lines = [];
  const text = (args) => args.map((a) => (typeof a === 'string' ? a : String(a))).join(' ');
  const methods = ['log', 'info', 'warn', 'error'];
  const savedConsole = Object.fromEntries(methods.map((m) => [m, console[m]]));
  const savedWrites = [process.stdout.write, process.stderr.write];
  const write = (chunk) => {
    lines.push(String(chunk));
    return true;
  };
  for (const m of methods) console[m] = (...args) => lines.push(text(args));
  process.stdout.write = write;
  process.stderr.write = write;
  try {
    const result = fn();
    const output = lines.join('\n').replace(ANSI, '');
    return { result, output, warnings: output.split('\n').filter((l) => l.startsWith('WARNING')) };
  } finally {
    for (const m of methods) console[m] = savedConsole[m];
    [process.stdout.write, process.stderr.write] = savedWrites;
  }
}

// Same shape as the customer snippets in aws/README.md. `parameters` replaces a template
// parameter with a fixed value. `defaults` only changes its default, which keeps the
// template's conditions open and so avoids CDK's "condition always true/false" warnings.
function addStack(app, stackId, region, parameters, defaults = {}) {
  const stack = new Stack(app, stackId, { env: { account: ACCOUNT, region } });
  const included = new CfnInclude(stack, 'Atomity', { templateFile: TEMPLATE, parameters });
  for (const [name, value] of Object.entries(defaults)) included.getParameter(name).default = value;
  return stack;
}
function synth(region, parameters, defaults) {
  const { result, warnings, output } = capture(() =>
    Template.fromStack(addStack(new App(), 'Atomity', region, parameters, defaults)),
  );
  result.warnings = warnings;
  result.output = output;
  return result;
}

const values = { ExternalId: 'test-external-id', BucketName: 'atomity-test-bucket' };

// This must stay first. The "prints no warnings" tests below pass trivially if capturing
// does not work in the runtime (it once did not under Bun), so prove capturing works here.
test('warning capture works in this runtime', () => {
  // Fixing the mode with `parameters` instead of defaults is what makes CDK print warnings.
  const t = synth('us-east-1', { ...values, EnableOrganizations: 'true', OrganizationRootId: 'r-ab12' });
  assert.ok(
    t.warnings.some((w) => /always return/.test(w)),
    `expected CDK warnings to be captured, got: ${JSON.stringify(t.output.slice(0, 300))}`,
  );
});

test('imports and synthesizes with the values a customer must set', () => {
  const t = synth('us-east-1', values).toJSON();
  assert.ok(Object.keys(t.Resources).length >= 4, 'resources were imported');
  assert.ok(Object.keys(t.Rules).includes('AccessNeedsUsEast1'), 'template rules were kept');
  assert.ok(Object.keys(t.Conditions).includes('CreateAccess'), 'conditions were kept');
  assert.ok(t.Outputs.RoleArn, 'the RoleArn output was kept');
});

test('a single-stack import prints no CDK warnings', () => {
  assert.deepEqual(synth('us-east-1', values).warnings, []);
});

test('creates the read-only role under its fixed name', () => {
  const t = synth('us-east-1', values);
  t.hasResourceProperties('AWS::IAM::Role', { RoleName: 'AtomityReadOnly' });
});

test('keeps the billing bucket when the stack is deleted', () => {
  const t = synth('us-east-1', values);
  t.hasResource('AWS::S3::Bucket', { DeletionPolicy: 'Retain', UpdateReplacePolicy: 'Retain' });
});

test('creates the FOCUS 1.2 Parquet export', () => {
  const t = synth('us-east-1', values);
  const exports = Object.values(t.findResources('AWS::BCMDataExports::Export'));
  assert.ok(exports.length >= 1);
  for (const e of exports) {
    const q = e.Properties.Export.DataQuery;
    assert.ok(Object.keys(q.TableConfigurations).includes('FOCUS_1_2_AWS'));
    assert.equal(e.Properties.Export.DestinationConfigurations.S3Destination.S3OutputConfigurations.Format, 'PARQUET');
  }
});

test('the role carries every statement of the shared permission policy', () => {
  const shared = JSON.parse(fs.readFileSync(PERMISSION, 'utf8')).Statement;
  const role = Object.values(synth('us-east-1', values).findResources('AWS::IAM::Role'))[0];
  const imported = role.Properties.Policies[0].PolicyDocument.Statement;
  assert.deepEqual(imported.map((s) => s.Sid).sort(), shared.map((s) => s.Sid).sort());
  for (const s of shared) {
    const match = imported.find((i) => i.Sid === s.Sid);
    assert.equal(match.Effect, s.Effect, s.Sid);
    assert.deepEqual([...match.Action].sort(), [...s.Action].sort(), s.Sid);
  }
});

test('the trust policy uses the supplied external ID', () => {
  const role = Object.values(synth('us-east-1', values).findResources('AWS::IAM::Role'))[0];
  const trust = role.Properties.AssumeRolePolicyDocument.Statement[0];
  assert.equal(trust.Action, 'sts:AssumeRole');
  assert.equal(trust.Condition.StringEquals['sts:ExternalId'], values.ExternalId);
});

test('the Organizations StackSet is part of the template, with no CDK warnings', () => {
  const t = synth('us-east-1', values, { EnableOrganizations: 'true', OrganizationRootId: 'r-ab12' });
  t.hasResourceProperties('AWS::CloudFormation::StackSet', {
    StackSetName: 'AtomityMemberRoles',
    PermissionModel: 'SERVICE_MANAGED',
  });
  assert.deepEqual(t.warnings, []);
});

test('a bucket outside us-east-1 works as two stacks in one app', () => {
  const app = new App();
  const { result, warnings } = capture(() => {
    const bucketStack = addStack(app, 'AtomityBucket', 'eu-central-1', { BucketName: values.BucketName }, { Deploy: 'BucketOnly' });
    const accessStack = addStack(app, 'Atomity', 'us-east-1', values, {
      Deploy: 'AccessOnly',
      BucketRegion: 'eu-central-1',
    });
    return [Template.fromStack(bucketStack).toJSON(), Template.fromStack(accessStack).toJSON()];
  });
  assert.ok(result[0].Resources.Bucket);
  assert.ok(result[1].Resources.Role);
  // CDK still reports two outputs that the bucket stack does not create. They are harmless, but
  // anything else (such as "condition will always return True") would mean the snippet got noisier.
  for (const w of warnings) assert.match(w, /Outputs\/(Region|Scope)/, w);
});

test('values left out stay as stack parameters, so they can be passed at deploy time', () => {
  const t = synth('us-east-1', { BucketName: values.BucketName });
  t.hasParameter('ExternalId', { NoEcho: true });
  const json = JSON.stringify(t.toJSON());
  assert.ok(!json.includes(values.ExternalId));
});