import { test } from 'magnitude-test';


test.group('shadow DOM arena', { url: 'localhost:8080/shadow' }, () => {
    test('dropdown test', async ({ ai }) => {
        await ai.step('Select option 2 in the dropdown');
    });

    test('colorpicker test', async ({ ai }) => {
        await ai.step('Put a bright green color in the color input');
    });

    test('date test', async ({ ai }) => {
        await ai.step('Put 01/01/2020 in the date input');
    });
})
