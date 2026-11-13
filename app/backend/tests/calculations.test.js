const { calculateMetrics } = require('../src/calculations');

const base = { weightKg: 70, heightCm: 175, age: 30, sex: 'male', activity: 'moderate' };

describe('calculateMetrics', () => {
  test('BMI is weight / height(m)^2, rounded to 1 decimal', () => {
    expect(calculateMetrics(base).bmi).toBe(22.9);
  });

  test.each([
    [50, 'Underweight'], // 16.3
    [70, 'Normal'],      // 22.9
    [80, 'Overweight'],  // 26.1
    [100, 'Obese']       // 32.7
  ])('weight %i kg at 175 cm is %s', (weightKg, category) => {
    expect(calculateMetrics({ ...base, weightKg }).bmiCategory).toBe(category);
  });

  test('category boundaries: 18.5 is Normal, 25 is Overweight, 30 is Obese', () => {
    // height 100 cm => BMI equals weight
    const at = (w) => calculateMetrics({ ...base, heightCm: 100, weightKg: w }).bmiCategory;
    expect(at(18.4)).toBe('Underweight');
    expect(at(18.5)).toBe('Normal');
    expect(at(25)).toBe('Overweight');
    expect(at(30)).toBe('Obese');
  });

  test('BMR uses Mifflin-St Jeor: +5 for male, -161 for female', () => {
    expect(calculateMetrics(base).bmr).toBe(1649);                     // 700+1093.75-150+5
    expect(calculateMetrics({ ...base, sex: 'female' }).bmr).toBe(1483); // ... -161
  });

  test.each([
    ['sedentary', 1.2],
    ['light', 1.375],
    ['moderate', 1.55],
    ['active', 1.725],
    ['very_active', 1.9]
  ])('daily calories for %s = BMR x %d', (activity, mult) => {
    const r = calculateMetrics({ ...base, activity });
    expect(r.dailyCalories).toBe(Math.round(1648.75 * mult));
  });

  test('unknown or missing activity falls back to sedentary (1.2)', () => {
    expect(calculateMetrics({ ...base, activity: 'couch' }).dailyCalories).toBe(Math.round(1648.75 * 1.2));
    expect(calculateMetrics({ ...base, activity: undefined }).dailyCalories).toBe(Math.round(1648.75 * 1.2));
  });
});
