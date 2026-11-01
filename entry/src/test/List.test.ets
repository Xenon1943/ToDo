import localUnitTest from './LocalUnit.test';
import coreLogicTest from './CoreLogic.test';

export default function testsuite() {
  localUnitTest();
  coreLogicTest();
}
