import { test } from 'magnitude-test';


test.group('scroll arena', { url: 'localhost:8080/scroll' }, () => {
    for (let target = 1; target <= 12; target++) {
        // Provide section as vague guidance
        const sections = [1, 1, 1, 2, 2, 3, 3, 3, 3, 4, 4, 4];
        test(`can find target ${target}`, async ({ ai }) => {
            await ai.step(`Find and click target labeled "Target ${target}" in Section ${sections[target-1]}`);
        });
    }
})
